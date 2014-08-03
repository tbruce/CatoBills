require 'fileutils'
require 'json'
require 'chronic'
require 'curb'
require 'nokogiri'
require 'net/http'
require 'trollop'
require 'rdf'
require 'ruby-prof'
require 'open-uri'
require 'cgi'
include RDF

HTTP_READ_TIMEOUT = 300
BILL_RETRY_COUNT = 5
BILL_RETRY_INTERVAL = 3

DEFAULT_XML_DUMPDIR = '/tmp/catoxml'
DEFAULT_TRIPLEFILE = '/tmp/catotriples.nt'

BILL_LIST_URL = 'http://deepbills.cato.org/api/1/bills'
BILL_API_PREFIX = 'http://deepbills.cato.org/api/1/bill?'
CONGRESS_GOV_PREFIX = 'https://beta.congress.gov/bill/'

DC_NS = 'http://purl.org/NET/dc_owl2dl/terms_od/'
CATO_NS = 'http://namespaces.cato.org/catoxml/'
LII_LEGIS_VOCAB = 'http://liicornell.org/legis/'
LII_TOP_VOCAB = 'http://liicornell.org/top/'
CO_VOCAB = 'http://purl.org/co/'
USC_URI_PREFIX = 'http://liicornell.org/id/uscode/'
STATL_URI_PREFIX = 'http://liicornell.org/id/statl/'
PUBL_URI_PREFIX = 'http://liicornell.org/id/publ/'
USC_PAGE_PREFIX = 'http://www.law.cornell.edu/uscode/text/'
# NB: PAY ATTENTION: there are hard-coded GPO URLS in the source code near line 350 (currently)

DBPEDIA_LOOKUP_PREFIX='http://lookup.dbpedia.org/api/search.asmx/KeywordSearch?QueryString='

# note on URI design for bills
# generally, looks like http://liicornell.org/id/congress/bills/[congressnum]/[billtype]/[number]
# where billtypes follow the GPO convention of h, s, hres, sres, hconres, sconres, hjres, sjres

BILL_URI_PREFIX = 'http://liicornell.org/id/us/congress/bills'
ACT_URI_PREFIX = 'http://liicornell.org/id/us/congress/acts'

# Factory class for Cato bills.  Methods in this class also manage the http
# connection with the Cato server, because it's more efficient to set them up
# and then hand them off to things that iterate over the whole bill list
class CatoBillFactory
  def initialize
    @bills = Array.new()
    @cong_num = calc_congress()
    fetch_bill_list
  end

  # get the Cato bill list and rubify
  def fetch_bill_list
    begin
      bill_list_uri = URI(BILL_LIST_URL)
      bill_list_json = Net::HTTP.get(bill_list_uri)
      if bill_list_json.nil?
        raise 'Cato bill list unavailable from Cato server'
      end
    rescue Exception => e
      $stderr.puts e.message
      $stderr.puts e.backtrace.inspect
    end
    raw_bill_list = JSON.parse(bill_list_json)
    puts "Raw bill list has #{raw_bill_list.length} items"

    # uniqify the bill list to most recent versions.
    # as it comes from Cato, it appears to be sorted by Cato bill number, and within the bill
    # number, by commit date. Not sure it's a good idea to rely on this, so we'll risk some duplicated effort by
    # sorting here.
    puts 'Sorting and de-duping bill list...'
    last_cato_num = -1
    raw_bill_list.sort_by{ |line| [line['billnumber'].to_i, Chronic.parse(line['commitdate']).strftime('%s').to_i]}.each do |item|
      @bills.pop if item['billnumber'] == last_cato_num
      @bills.push(item)
      last_cato_num = item['billnumber']
    end
    puts '...sorted.'
    puts "Most-recentized bill list has #{@bills.length} items"
  end

  # dump most recent versions as XML
  def dump_xml_bills(dumpdir, exclude_intros)
    billcount = 0
    server_uri = URI(BILL_API_PREFIX)
    httpcon = Net::HTTP.new(server_uri.host, server_uri.port)
    httpcon.read_timeout = HTTP_READ_TIMEOUT
    httpcon.start do |http|
      @bills.each do |item|
        next if exclude_intros && item['billversion'] =~ /^i/
        bill = CatoBill.new(item)
        bill.populate(httpcon)
        next if bill.xml.nil?
        myfile = File.new(dumpdir + '/' + bill.uri.to_s.split(/\//).pop + '.xml', 'w')
        myfile << bill.xml
        billcount += 1
      end
    end
    puts "#{billcount} bills processed"
  end

  def take_status_census(exclude_intros = false)
    census = Hash.new()
    billcount = 0
    server_uri = URI(BILL_API_PREFIX)
    httpcon = Net::HTTP.new(server_uri.host, server_uri.port)
    httpcon.read_timeout = HTTP_READ_TIMEOUT
    httpcon.start do |http|
      @bills.each do |billparms|
        if census[billparms['billversion']].nil?
          census[billparms['billversion']] = 1
        else
          census[billparms['billversion']] += 1
        end
        billcount += 1
      end
    end
    # print census sorted by values
    census.sort_by { |btype, count| btype }.each do |stage, num|
      puts "#{stage} : #{num}\n"
    end
  end

  def triplify_refs (triplefile, exclude_intros = false)
    server_uri = URI(BILL_API_PREFIX)
    billcount = 0
    frdf = File.open(triplefile, 'w+')
    httpcon = Net::HTTP.new(server_uri.host, server_uri.port)
    httpcon.read_timeout = HTTP_READ_TIMEOUT
    httpcon.start do |http|
      @bills.each do |item|
        next if exclude_intros && item['billversion'] =~ /^i/
        bill = CatoBill.new(item)
        bill.populate(httpcon)
        next if bill.xml.nil?
        bill.extract_refs
       # bill.extract_orgs
        bill.express_triples(frdf)
        billcount += 1
      end
    end
    frdf.close
    puts "#{billcount} bills processed."
  end


  # calculates the number of the current Congress
  def calc_congress
    # is this an odd-numbered year? if not, pick last year instead
    my_year = DateTime.now.strftime('%Y').to_i
    my_year = my_year -1 unless my_year.odd?
    return ((my_year - 1787 )/ 2 )
  end
end

class CatoBill

  attr_reader :stage, :title, :dctitle, :short_title :legisnum, :type
  attr_reader :genre, :congress, :version, :uri, :pathish_uri, :xml

  # unfortunately, constructor failure is very hard to handle in ruby, especially if creation of the object
  # depends on (eg) fetching something from the net. it makes sense to use separate methods to construct an
  # object and to populate its data, even if an unpopulated object is useless --

  def initialize (in_bill)
    @type = in_bill['billtype']
    @billnum = in_bill['billnumber']
    @version = in_bill['billversion']
    @congress = in_bill['congress']
    @uri = nil
    @genre = nil
    @stage = nil
    @title = nil
    @dctitle = nil
    @short_title = nil
    @legisnum = nil
    @xml = nil
    @refstrings = Array.new()
    @entrefs = Array.new()
  end

  # get all the content of the bill, and its metadata
  def populate (httpcon = nil)
    @xml = fetch_bill(httpcon)
    return nil if @xml.nil?
    extract_meta
  end

  # just grab the bill stage as quickly as possible
  def grab_stage_fast(httpcon = nil)
    @xml = fetch_bill(httpcon)
    return nil if @xml.nil?
    if @xml =~ /^<bill/
      @stage = /\s+bill-stage="(.*?)"/.match(@xml)[1]
    elsif @xml =~ /^<resolution/
      @stage = /\s+resolution-stage="(.*?)"/.match(@xml)[1]
    end
    return @stage
  end

  # pull bill via Cato API
  def fetch_bill (httpcon = nil)
    params = "billnumber=#{@billnum}&billversion=#{@version}&congress=#{@congress}&billtype=#{@type}"
    # Cato bill list fetches fine -- it's the API that times out sometimes. So we get all defensive...
    retries = BILL_RETRY_COUNT
    start = Time.now
    begin
      if httpcon.nil?
        bill_uri = URI(BILL_API_PREFIX + params)
        httpcon = Net::HTTP.new(bill_uri.host, bill_uri.port)
        httpcon.read_timeout = HTTP_READ_TIMEOUT
      end
      resp = httpcon.get(BILL_API_PREFIX + params)
    rescue StandardError, Timeout::Error => e
     sleep BILL_RETRY_INTERVAL
     retry if (retries -= 1) > 0
    end
    if resp.nil?
      puts "Bill fetch failed for bill number #{@billnum}"
      return nil
    end
    finish = Time.now
    puts "Fetched bill number #{@billnum}, tries =  #{BILL_RETRY_COUNT - retries + 1}, tt = #{finish - start}"
    billhash = JSON.parse(resp.body)
    return billhash['billbody']
  end

  # extract any interesting bill metadata
  def extract_meta
    doc = Nokogiri::XML(@xml)
    stageattr = nil
    if @type =~ /res$/
      @genre = 'resolution'
      stageattr = 'resolution-stage'
    end
    if @type =~ /^(hr|s)$/
      @genre = 'bill'
      stageattr = 'bill-type'
    end
    @stage = doc.xpath("//#{@genre}").attr(stageattr).content unless ( doc.xpath("//#{@genre}").nil? || doc.xpath("//#{@genre}").attr(stageattr).nil? )
    @title = doc.xpath('//official-title').first.content.gsub(/[\s\t\n]+/,' ')
    @dctitle = doc.xpath('//dc:title', 'dc' => DC_NS).first.content unless doc.xpath('//dc:title', 'dc' => DC_NS).first.nil?
    @dctitle = title.dup if @dctitle.nil?
    @short_title = doc.xpath('//short-title').first.content unless doc.xpath('short-title').first.nil?
    @legisnum = doc.xpath('//legis-num').first.content
    bflat = @legisnum.gsub(/\.\s+/, '_').downcase
    bnumber = @legisnum.split(/\s+/).last
    @uri = RDF::URI("#{BILL_URI_PREFIX}/#{@congress}_#{bflat}")
  end

  # extract all references from the bill
  # Cato documentation for XML schema is at http://namespaces.cato.org/catoxml
  def extract_refs
    doc = Nokogiri::XML(@xml)
    doc.remove_namespaces!  # dangerous, but OK in this case b/c Cato was careful about overlaps
    doc.xpath("//entity-ref[@entity-type='act']").each do |refelem|
      @refstrings.push(refelem.attr('value'))
    end
    doc.xpath("//act-name").each do |refelem|
      @refstrings.push(refelem.content)
    end
    doc.xpath("//entity-ref[@entity-type='uscode']").each do |refelem|
      @refstrings.push(refelem.attr('value'))
    end
    doc.xpath("//external-xref[@legal-doc='usc']").each do |refelem|
      @refstrings.push(refelem.attr('parsable-cite'))
    end
    doc.xpath("//external-xref[@legal-doc='usc-chapter']").each do |refelem|
      @refstrings.push(refelem.attr('parsable-cite'))
    end
    doc.xpath("//external-xref[@legal-doc='usc-appendix']").each do |refelem|
      @refstrings.push(refelem.attr('parsable-cite'))
    end
    doc.xpath("//entity-ref[@entity-type='public-law']").each do |refelem|
      @refstrings.push(refelem.attr('value'))
    end
    doc.xpath("//external-xref[@legal-doc='public-law']").each do |refelem|
      @refstrings.push(refelem.attr('parsable-cite'))
    end
    doc.xpath("//entity-ref[@entity-type='statute-at-large']").each do |refelem|
      @refstrings.push(refelem.attr('value'))
    end
    doc.xpath("//external-xref[@legal-doc='statute-at-large']").each do |refelem|
      @refstrings.push(refelem.attr('parsable-cite'))
    end
    # uniqify
    @refstrings.uniq!
    puts 'Refstrings compiled...'
  end

  def extract_orgs
    #TODO
  end

  # generate triples and write them to a file
  def express_triples(frdf)
    # set up vocabularies
    legis = RDF::Vocabulary.new(RDF::URI(LII_LEGIS_VOCAB))
    liivoc = RDF::Vocabulary.new(RDF::URI(LII_TOP_VOCAB))
    covoc = RDF::Vocabulary.new(RDF::URI(CO_VOCAB))

  begin
    # write triples into string buffer
    rdfout = RDF::Writer.for(:ntriples).buffer do |writer|
      # write all metadata triples
      # put me in the graph
      writer << [@uri, RDF.type, legis.LegislativeMeasure]
      writer << [@uri, DC.title, @dctitle]
      writer << [@uri, legis.hasShortTitle, @short_title] unless @short_title.nil?
      # put my congress.gov page in the graph
      utype = 'senate-bill' if @legisnum =~/^S/
      utype = 'house-bill' if @legisnum =~/^H/
      cgurl = CONGRESS_GOV_PREFIX + "#{ordinalize(@congress)}-congress/#{utype}/#{@billnum}"
      writer << [@uri, liivoc.hasPage, RDF::URI(cgurl)]
      #now process all reference strings from the doc
      @refstrings.each do |ref|
        next if ref.nil?  #TODO not sure how this can happen; should probably trap for it elsewhere
        refparts = ref.split(/\//)
        reftype = refparts.shift if refparts.length > 1
        reftitle = refparts.shift
        refuri = nil
        parenturi = nil
        firsturi = nil
        lasturi = nil
        case reftype
          when 'usc' # US Code section reference of some kind
            if refparts.last =~ /\.\./ # it's a run of sections or subsections
              refstring = refparts.join('_')
              rangestr = refparts.pop
              rangebase = refparts.join('_')
              refuri = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{refstring}")
              firsturi = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{rangebase}_" + rangestr.split(/\.\./).first)
              lasturi = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{rangebase}_" + rangestr.split(/\.\./).last)
              writer << [refuri, RDF.type, liivoc.UniqueList]
              writer << [refuri, covoc.firstItem, firsturi]
              writer << [refuri, covoc.lastItem, lasturi]
              writer << [@uri, liivoc.refUSCodeCollection, refuri] unless refuri.nil?
            elsif refparts.last =~ /etseq/ # it's a range
              refstring = refparts.join('_')
              refparts.pop # dump the "/etseq" off the end
              firststr = refparts.join('_')
              refuri = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{refstring}")
              firsturi = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{firststr}")
              writer << [refuri, RDF.type, liivoc.UniqueList]
              writer << [refuri, covoc.firstItem, firsturi]
              writer << [@uri, liivoc.refUSCodeCollection, refuri] unless refuri.nil?
            elsif refparts.last =~ /note/ # it's a section note; there are no subsection notes
              refstring = refparts.join('_')
              refuri = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{refstring}")
              writer << [@uri, liivoc.refUSCode, refuri] unless refuri.nil?
              pagestr = USC_PAGE_PREFIX + "#{reftitle}/#{refparts[0]}"
              writer << [refuri, liivoc.hasPage, RDF::URI(pagestr)]
              writer << [RDF::URI(pagestr)], RDF.type, liivoc.LegalWebPage ]
            else # it's a simple section or subsection reference
              refstring = refparts.join('_')
              refuri = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{refstring}")
              writer << [@uri, liivoc.refUSCode, refuri] unless refuri.nil?
              if refparts.length > 1 # subsection reference
                parenturi = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{refparts[0]}")
                writer << [parenturi, liivoc.containsTransitive, refuri]
                pagestr = USC_PAGE_PREFIX + "#{reftitle}/#{refparts[0]}"
                writer << [parenturi, liivoc.hasPage, RDF::URI(pagestr)]
                writer << [RDF::URI(pagestr)], RDF.type, liivoc.LegalWebPage ]
              else
                pagestr = USC_PAGE_PREFIX + "#{reftitle}/#{refparts[0]}"
                writer << [refuri, liivoc.hasPage, RDF::URI(pagestr)]
                writer << [RDF::URI(pagestr)], RDF.type, liivoc.LegalWebPage ]
              end
            end
          when 'usc-chapter'
            if refparts.last =~ /etseq/ # it's a range of chapters (does this really happen?)
              next # can't handle these yet
            elsif refparts.last =~ /note/
              refparts.pop # get rid of the "/note"
              refchapter = refparts.shift
              refsubchapter = refparts.shift unless refparts.length == 0
              uristr = USC_URI_PREFIX + "#{reftitle}_USC_chapter_#{refchapter}"
              uristr += "_subchapter_#{refsubchapter}" unless refsubchapter.nil?
              uristr += '_note'
              writer << [@uri, liivoc.refUSCode, RDF::URI(uristr)]
              pagestr = USC_PAGE_PREFIX + "#{reftitle}/chapter-#{refchapter}"
              pagestr += "/subchapter-#{refsubchapter}" unless refsubchapter.nil?
              writer << [RDF::URI(uristr), liivoc.hasPage, RDF::URI(pagestr)]
              writer << [RDF::URI(pagestr)], RDF.type, liivoc.LegalWebPage ]
            else # it's a simple chapter or subchapter reference
              refchapter = refparts.shift
              refsubchapter = refparts.shift unless refparts.length == 0
              uristr = USC_URI_PREFIX + "#{reftitle}_USC_chapter_#{refchapter}"
              uristr += "_subchapter_#{refsubchapter}" unless refsubchapter.nil?
              writer << [@uri, liivoc.refUSCode, RDF::URI(uristr)]
              pagestr = USC_PAGE_PREFIX + "#{reftitle}/chapter-#{refchapter}"
              pagestr += "/subchapter-#{refsubchapter}" unless refsubchapter.nil?
              writer << [RDF::URI(uristr), liivoc.hasPage, RDF::URI(pagestr)]
              writer << [RDF::URI(pagestr)], RDF.type, liivoc.LegalWebPage ]
            end
          when 'usc-appendix'
            next #TODO not handling these right now
          when 'public-law'
            uristr = PUBL_URI_PREFIX + "#{reftitle}_PL_#{refparts[0]}"
            writer << [@uri , liivoc.refPubL, RDF::URI(uristr)]
            pagestr = "http://www.gpo.gov/fdsys/pkg/PLAW-#{reftitle}publ#{refparts[0]}/pdf/PLAW-#{reftitle}publ#{refparts[0]}.pdf"
            writer << [RDF::URI(uristr), liivoc.hasPage, RDF::URI(pagestr)]    #blah
            writer << [RDF::URI(pagestr)], RDF.type, liivoc.LegalWebPage ]
          when 'statute-at-large'
            uristr = STATL_URI_PREFIX + "#{reftitle}_Stat_#{refparts[0]}"
            writer << [@uri , liivoc.refStatL, RDF::URI(uristr)]
            # Volume 65 of StatL is currently the earliest available at GPO
            if reftitle.to_i >= 65
              pagestr = "http://www.gpo.gov/fdsys/pkg/STATUTE-#{reftitle}/pdf/STATUTE-#{reftitle}pg#{refparts[0]}.pdf"
              writer << [RDF::URI(uristr) , liivoc.hasPage, RDF::URI(pagestr)]
              writer << [RDF::URI(pagestr)], RDF.type, liivoc.LegalWebPage ]
            end
          else # it's an act
            # "stem" it and record a URI
            # we're picking up section-level references without titles, I think
            if reftitle =~ /^[A-Z]/
              acturi = RDF::URI(ACT_URI_PREFIX + '/' + reftitle.gsub(/[\s,]/,'_'))
              writer << [@uri, legis.refAct, acturi ]
            end
            #TODO: pull a PL reference if possible
            # if we get a PL reference, check to see if there's a section. If so, try Table 3 for an actual USC cite
            # also record the entire Cato ref in case we find a use for it.
            writer << [@uri, legis.hasCatoRef, ref ]
            # check for dbPedia article on the Act
            dbpuri = get_dbpedia_ref(reftitle.split(/:/)[0])
            unless dbpuri.nil?
              writer << [@uri, liivoc.refDBPedia, RDF::URI(dbpuri)]
            end
        end
      end
    end
    rescue RDF::WriterError => e
      puts e.message
      puts e.backtrace.inspect
    end
    frdf << rdfout # dump buffer to file
  end

  # find the ordinal expression for an integer
   def ordinalize(myi)
    if (11..13).include?(myi % 100)
      "#{myi}th"
    else
      case myi % 10
        when 1; "#{myi}st"
        when 2; "#{myi}nd"
        when 3; "#{myi}rd"
        else    "#{myi}th"
      end
    end
   end

  # search for a legal resource in dbPedia. results of a search could be anything
  # so we filter by looking for "law words" in the category
  def get_dbpedia_ref(lookupstr)
    looker = DBPEDIA_LOOKUP_PREFIX + "#{CGI::escape(lookupstr)}"
    c = Curl.get(looker) do |c|
      c.headers['Accept'] = 'application/json'
    end

    # unfortunately, the QueryClass parameter for dbPedia lookups is not much help, since class information
    # is often missing.  Best alternative is to use a filter based on dbPedia categories.  Crudely implemented
    # here as a string match against a series of keywords

    JSON.parse(c.body_str)['results'].each do |entry|
      use_me = false
      entry['categories'].each do |cat|
        use_me = true if cat['label'] =~ /\b(law|legislation|government|Act)\b/
      end
      return entry['uri'] if use_me
    end
    return nil
  end

end

# class that runs this show
class CatoRunner

  def initialize(opt_hash)
    @opts = opt_hash
    @factory = CatoBillFactory.new()
    @exclude_intros = false
    @exclude_intros = true if @opts.exclude_intros
  end

  def run
    RubyProf.start if @opts.profile_me
    @factory.take_status_census(@exclude_intros) if @opts.take_census
    if @opts.triplify_refs
      @opts.triplify_refs = DEFAULT_TRIPLEFILE if @opts.triplify_refs.nil?
      @factory.triplify_refs(@opts.triplify_refs, @exclude_intros)
    end
    if @opts.dump_xml_bills
      @opts.dump_xml_bills = DEFAULT_XML_DUMPDIR if @opts.dump_xml_bills.nil?
      Dir.mkdir(@opts.dump_xml_bills) unless Dir.exist?(@opts.dump_xml_bills)
      @factory.dump_xml_bills(@opts.dump_xml_bills,@exclude_intros)
    end
    if @opts.profile_me
      result = RubyProf.stop
      printer = RubyProf::FlatPrinter.new(result)
      printer.print(STDOUT, {})
    end
  end

end

# set up command line options
opts = Trollop::options do
  banner <<-EOBANNER
CatoBills is a Swiss Army knife for working with Cato's "deepbills" data; see their
project documentation at deepbills.cato.org

Usage:
    CatoBills.rb [options]
where options are:
  EOBANNER
  opt :take_census, 'Take a census of bill-stage information'
  opt :dump_xml_bills, 'Dump latest versions of XML bills as files' , :type => :string, :default => nil
  opt :triplify_refs, 'Create n-triples representing references to primary law in each bill', :type => :string, :default => nil
  opt :profile_me, 'Invoke the Ruby profiler on this code'
  opt :exclude_intros, 'Exclude introduction-only bills'
end

runner = CatoRunner.new(opts)
runner.run
puts 'done.'

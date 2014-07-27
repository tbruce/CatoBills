require 'fileutils'
require 'json'
require 'chronic'
require 'nokogiri'
require 'net/http'
require 'trollop'
require 'rdf'
require 'ruby-prof'
require 'open-uri'
include RDF

HTTP_READ_TIMEOUT = 300
BILL_RETRY_COUNT = 5
BILL_RETRY_INTERVAL = 3
BILL_LIST_URL = 'http://deepbills.cato.org/api/1/bills'
BILL_API_PREFIX = 'http://deepbills.cato.org/api/1/bill?'
CONGRESS_GOV_PREFIX = 'https://beta.congress.gov/bill/'

DC_NS = 'http://purl.org/dc/elements/1.1/'
CATO_NS = 'http://namespaces.cato.org/catoxml/'
LII_LEGIS_VOCAB = 'http://liicornell.org/legis/'
LII_TOP_VOCAB = 'http://liicornell.org/top/'
USC_URI_PREFIX = 'http://liicornell.org/id/uscode/'


# note on URI design for bills
# generally, looks like http://liicornell.org/id/congress/bills/[congressnum]/[billtype]/[number]
# where billtypes follow the GPO convention of h, s, hres, sres, hconres, sconres, hjres, sjres

BILL_URI_PREFIX = 'http://liicornell.org/id/us/congress/bills'

# Factory class for Cato bills
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
    # sorting here
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
    # check to see that we have the directory that we need
    server_uri = URI(BILL_API_PREFIX)
    httpcon = Net::HTTP.new(server_uri.host, server_uri.port)
    httpcon.read_timeout = HTTP_READ_TIMEOUT
    httpcon.start do |http|
      @bills.each do |item|
        next if exclude_intros && item['billversion'] =~ /^i/
        bill = CatoBill.new(item)
        bill.populate(httpcon)
        myfile = File.new(dumpdir + '/' + bill.uri.to_s.split(/\//).pop + '.xml', 'w')
        myfile << bill.xml
      end
    end
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
    frdf = File.open(triplefile, 'w+')
    httpcon = Net::HTTP.new(server_uri.host, server_uri.port)
    httpcon.read_timeout = HTTP_READ_TIMEOUT
    httpcon.start do |http|
      @bills.each do |item|
        next if exclude_intros && item['billversion'] =~ /^i/
        bill = CatoBill.new(item)
        bill.populate(httpcon)
        bill.extract_refs(frdf)
      end
    end
    frdf.close
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

  attr_reader :stage, :title, :dctitle, :legisnum, :type, :genre, :congress, :version, :uri, :pathish_uri,:xml

  # why both initialize and populate?  constructor failure is very hard to handle
  # intelligently in Ruby if it involves anything more than argument errors, so you don't want to make it dependent
  # on (eg) network fetches or other things prone to runtime problems. Yes, the object is useless if it can't get its
  # content over the network, but that doesn't mean that the network fetch should be in the constructor ;)

  def initialize (in_bill)
    @type = in_bill['billtype']
    @billnum = in_bill['billnumber']
    @version = in_bill['billversion']
    @congress = in_bill['congress']
    @uri = nil
    @pathish_uri = nil
    @genre = nil
    @stage = nil
    @title = nil
    @dctitle = nil
    @legisnum = nil
    @xml = nil
  end

  # get all the content of the bill, and its metadata
  def populate (httpcon = nil)
    @xml = fetch_bill (httpcon)
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
      $stderr.puts "Cato bill fetch failed for bill number #{@billnum}"
      return nil
    end
    finish = Time.now
    puts "Fetched Cato bill number #{@billnum}, tries =  #{BILL_RETRY_COUNT - retries + 1}, tt = #{finish - start}"
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
    @legisnum = doc.xpath('//legis-num').first.content
    bflat = @legisnum.gsub(/\.\s+/, '_').downcase
    bnumber = @legisnum.split(/\s+/).last
    @pathish_uri = RDF::URI("#{BILL_URI_PREFIX}/#{@congress}/#{@type}/#{bnumber}")
    @uri = RDF::URI("#{BILL_URI_PREFIX}/#{@congress}_#{bflat}")
  end

  # extract all references from the bill
  # Cato documentation is at http://namespaces.cato.org/catoxml
  def extract_refs(frdf)
    doc = Nokogiri::XML(@xml)
    legis = RDF::Vocabulary.new(RDF::URI(LII_LEGIS_VOCAB))
    liivoc = RDF::Vocabulary.new(RDF::URI(LII_TOP_VOCAB))
    rdfout = RDF::Writer.for(:ntriples).buffer do |writer|


      # put my congress.gov page in the graph
      utype = 'senate-bill' if @legisnum =~/^S/
      utype = 'house-bill' if @legisnum =~/^H/
      cgurl = CONGRESS_GOV_PREFIX + "#{ordinalize(@congress)}-congress/#{utype}/#{@billnum}"

      # put my metadata in the graph.  lots can be done here to populate legis model, not sure we want to
      # get US Code refs and put them in the graph
      extract_uscode_refs(doc, liivoc, writer)
      # extract act references (entity-ref entity-type attribute is 'act')
      # extract PubL references (entity-ref entity-type attribute is 'public-law')
      # extract StatL references (entity-ref entity-type attribute is 'statute-at-large')
      begin
        # put me in the graph
        writer << [@uri, RDF.type, legis.LegislativeMeasure]
        # put my equivalent path-ish URI in the graph
        writer << [@pathish_uri, RDF.type, legis.LegislativeMeasure]
        writer << [@pathish_uri, OWL.sameAs, @uri]
        writer << [@uri, FOAF.page, RDF::URI(cgurl)]
      rescue RDF::WriterError => e
        puts e.message
        puts e.backtrace.inspect
        next
      end

    end
    frdf << rdfout # dump buffer to file
  end
  # extract uscode references (entity-ref entity-type attribute is 'uscode')
      # these consist of:
      # simple section references
      # references to subsections
      # references to ranges of sections or subsections
      # references to notes and et-seqs
      # simple chapter and subchapter references
      # ranges of chapters and subchapters
      # references to appendices, sometimes with a section
  def extract_uscode_refs(doc, liivoc, writer)
    # simple section references
    puts "entered usc-extract"
    doc.xpath("//cato:entity-ref[@entity-type='uscode']", 'cato' => CATO_NS).each do |ref|
      refparts = ref['value'].split(/\//)
      reftype = refparts.unshift
      reftitle = refparts.unshift
      refuri = nil
      parenturi = nil
      case reftype
        when 'usc'
          if refparts.last =~ /\.\./ # it's a range; could be section or subsection
            return # can't handle these yet
          elsif refparts.last =~ /etseq/ # it's a range
            return # can't handle these yet
          elsif refparts.last =~ /note/ # it's a section note; there are no subsection notes
            refstring = refparts.join('_')
            refuri = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{refstring}")

          else # it's a simple section or subsection reference
            refstring = refparts.join('_')
            refuri = RDF::URI(USC_URI_PREFIX + "#{reftitle}_USC_#{refstring}")

            if refparts.length > 1 # simple section reference
              parenturi = RDF::URI(USC_URI_PREFIX + '_USC_' + refparts[0])

            end
          end
        when 'usc-chapter'
          if refparts.last =~ /etseq/ # it's a range of chapters (does this really happen?)
            return # can't handle these yet
          elsif refparts.last =~ /note/

          else # it's a simple chapter or subchapter reference
            refstring = refparts.join('_')
          end
        when 'usc-appendix'
      end
      begin
        writer << [@uri, DC.references, refuri] unless refuri.nil?
        writer << [refuri, liivoc.belongsToTransitive, parenturi] unless parenturi.nil?
      rescue RDF::WriterError => e
        puts e.message
        puts e.backtrace.inspect
        next
      end

    end

  end

  def extract_publ_refs

  end

  def extract_statl_refs

  end

  def extract_act_refs

  end

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

end

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
    @factory.triplify_refs(@opts.triplify_refs, @exclude_intros) if @opts.triplify_refs

    if @opts.dump_xml_bills
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

opts = Trollop::options do
  banner <<-EOBANNER
CatoBills is a Swiss Army knife for working with Cato's "deepbills" data; see their
project documentation at deepbills.cato.org

Usage:
    CatoBills.rb [options]
where options are:
  EOBANNER
  opt :take_census, 'Take a census of bill-stage information'
  opt :dump_xml_bills, 'Dump latest versions of XML bills as files' , :default => '/tmp/catobills', :type => :string
  opt :triplify_refs, 'Create n-triples representing references to primary law in each bill', :type => :string, :default => nil
  opt :profile_me, 'Invoke the Ruby profiler on this code'
  opt :exclude_intros, 'Exclude introduction-only bills'
end

runner = CatoRunner.new(opts)
runner.run
puts 'done.'

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

# note on URI design for bills
# generally, looks like http://liicornell.org/id/congress/bills/[congressnum]/[billtype]/[number]
# where billtypes follow the GPO convention of h, s, hres, sres, hconres, sconres, hjres, sjres

BILL_URI_PREFIX = 'http://liicornell.org/id/us/congress/bills'

# Factory class for Cato bills
class CatoBillFactory
  def initialize
    @bills = Array.new()
    @cong_num = calc_Congress()
    fetch_bill_list
  end

  # get the Cato bill list and rubify
  def fetch_bill_list
    begin
      bill_json = nil
      bill_list_uri = URI(BILL_LIST_URL)
      bill_list_json = Net::HTTP.get(bill_list_uri)
      if bill_list_json.nil?
        raise "Cato bill list unavailable from Cato server"
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
    puts "Sorting and de-duping bill list..."
    last_cato_num = -1
    raw_bill_list.sort_by{ |line| [line['billnumber'].to_i, Chronic.parse(line['commitdate']).strftime('%s').to_i]}.each do |item|
      @bills.pop if item['billnumber'] == last_cato_num
      @bills.push(item)
      last_cato_num = item['billnumber']
    end
    puts "...sorted."
    puts "Most-recentized bill list has #{@bills.length} items"

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
  def triplify_refs (exclude_intros = false)

  end
  def jsonify_for_usc

  end

  # calculates the number of the current Congress
  def calc_Congress
    # is this an odd-numbered year? if not, pick last year instead
    my_year = DateTime.now.strftime('%Y').to_i
    my_year = my_year -1 unless my_year.odd?
    return ((my_year - 1787 )/ 2 )
  end
end

class CatoBill

  attr_reader :stage, :title, :legisnum, :type, :genre, :congress, :version, :uri, :pathish_uri

  # why both initialize and populate?  constructor failure is very hard to handle
  # intelligently in Ruby if it involves anything more than argument errors, so you don't want to make it dependent
  # on (eg) network fetches or other things prone to runtime problems. Yes, the object is useless if it can't get its
  # content over the network, but that doesn't mean that the network fetch should be in the constructor ;)

  def initialize (in_bill)
    @type = in_bill['billtype']
    @catonum = in_bill['billnumber']
    @version = in_bill['billversion']
    @congress = in_bill['congress']
    @uri = nil
    @pathish_uri = nil
    @genre = nil
    @stage = nil
    @title = nil
    @legisnum = nil
    @xml = nil
    @act_refs = Array.new #strings representing act reference URIs
    @uscode_refs = Array.new #strings representing US Code reference URIs
    @publ_refs = Array.new #strings representing public law refs
    @statl_refs = Array.new #strings representing Statutes at Large refs
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
    params = "billnumber=#{@catonum}&billversion=#{@version}&congress=#{@congress}&billtype=#{@type}"
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
      $stderr.puts "Cato bill fetch failed for bill number #{@catonum}"
      return nil
    end
    finish = Time.now
    puts "Fetched Cato bill number #{@catonum}, tries =  #{BILL_RETRY_COUNT - retries + 1}, tt = #{finish - start}"
    billhash = JSON.parse(resp.body)
    return billhash['billbody']
  end

  # extract any interesting bill metadata
  def extract_meta
    @doc = Nokogiri::XML(@xml)
    if @type =~ /res$/
      @genre = 'resolution'
      stageattr = 'resolution-stage'
    end
    if @type =~ /^(hr|s)$/
      @genre = 'bill'
      stageattr = 'bill-type'
    end
    @stage = @doc.xpath("//#{@genre}").attr(stageattr).content unless ( @doc.xpath("//#{@genre}").nil? || @doc.xpath("//#{@genre}").attr(stageattr).nil? )
    @title = @doc.xpath('//official-title').first.content
    @legisnum = @doc.xpath('//legis-num').first.content
    bflat = @legisnum.gsub(/\.*\s+/, '_').downcase
    bnumber = @legisnum.split(/\s+/).last

    @pathish_uri = "#{BILL_URI_PREFIX}/#{@congress}/#{@type}/#{bnumber}"
    @uri = "#{BILL_URI_PREFIX}/#{@congress}_#{@bflat}"
    return 1
  end

  # extract references from the bill
  # Cato documentation is at http://namespaces.cato.org/catoxml
  # Our aim is to resolve everything into a series of US Code section and subsection references.
  # Any application would then rely on knowledge of USC structure to get more specific targets.
  # So, we need to
  # -- expand subsection ranges and etseqs into lists.
  # -- expand section ranges and etseqs into lists.
  # -- deal with StatL ranges. These should not necessarily be enumerated.
  # -- deal with popular name references. These are handled in two ways.
  #    -- if a portion of the reference (act and section)
  #
  def extract_refs







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
  def extract_uscode_refs

  end
  # extract act references (entity-ref entity-type attribute is 'act')
  def extract_act_refs

  end
  # extract PubL references (entity-ref entity-type attribute is 'public-law')
  def extract_publ_refs

  end
  # extract StatL references (entity-ref entity-type attribute is 'statute-at-large')
  def extract_statl_refs

  end



  def triplify

  end

end

class CatoRunner
  def initialize(opt_hash)
    @opts =opt_hash
    @f = CatoBillFactory.new()
    @exclude_intros = false
    @exclude_intros = true if @opts.exclude_intros
  end

  def run
    RubyProf.start if @opts.profile_me
    @f.take_status_census(@exclude_intros) if @opts.take_census
    @f.triplify_refs(@exclude_intros) if @opts.triplify_refs

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
  opt :take_census, "Take a census of bill-stage information"
  opt :triplify_refs, "Create n-triples representing references to primary law in each bill"
  opt :profile_me, "Invoke the Ruby profiler on this code"
  opt :exclude_intros, "Exclude introduction-only bills"
  #opt :dump_files,      dump the bill files
end

f = CatoBillFactory.new

RubyProf.start
f.take_status_census


puts "done"

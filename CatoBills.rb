require 'json'
require 'chronic'
require 'nokogiri'
require 'net/http'
require 'trollop'
require 'rdf'
require 'ruby-prof'
include RDF

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
    last_cato_num = -1
    raw_bill_list.sort_by{ |line| [line['billnumber'].to_i, Chronic.parse(line['commitdate']).strftime('%s').to_i]}.each do |item|
      @bills.pop if item['billnumber'] == last_cato_num
      @bills.push(item)
      last_cato_num = item['billnumber']
    end
    puts "Most-recentized bill list has #{@bills.length} items"

  end

  def take_status_census
    census = Hash.new()
    billcount = 0
    @bills.each do |billparms|
      puts "processing bill #{billcount}, Cato #{billparms['billnumber']}"
      bill = CatoBill.new(billparms)
      if census[bill.stage].nil?
        census[bill.stage] = 1
      else
        census[bill.stage] = census[bill.stage] + 1
      end
      billcount = billcount + 1
    end
    # print census sorted by values
    census.sort_by {|btype, count| btype}.each do | stage, num |
      puts "#{stage} : #{num}\n"
    end
  end
  def triplify_bills

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
    @xml = fetch_bill
    #TODO -- nil result
    extract_meta
  end

  # pull bill via Cato API
  def fetch_bill
    params = "billnumber=#{@catonum}&billversion=#{@version}&congress=#{@congress}&billtype=#{@type}"
    begin
      bill_json = nil
      bill_uri = URI(BILL_API_PREFIX + params)
      bill_json = Net::HTTP.get(bill_uri)
      if bill_json.nil?
        raise "Cato bill fetch failed for bill number #{@catonum}"
        return nil
      end
    rescue Exception => e
      $stderr.puts e.message
      $stderr.puts e.backtrace.inspect
      return nil
    end
    return if bill_json.nil?
    billhash = JSON.parse(bill_json)
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

  end
  def triplify

  end

end

f = CatoBillFactory.new

RubyProf.start
f.take_status_census
result = RubyProf.stop
printer = RubyProf::FlatPrinter.new(result)
printer.print(STDOUT, {})

puts "done"

require 'json'
require 'nokogiri'
require 'net/http'
require 'trollop'
require 'rdf'
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
    @bills = Hash.new()
    @cong_num = calc_Congress()
    fetch_bill_list
  end

  # get the Cato bill list and rubify
  def fetch_bill_list
    begin
      bill_list_uri = URI(BILL_LIST_URL)
      bill_list_json = Net::HTTP.get(bill_list_uri)
      unless bill_list_json
        raise "Cato bill list unavailable from Cato server"
      end
    rescue Exception => e
      $stderr.puts e.message
      $stderr.puts e.backtrace.inspect
    end
    @bills = JSON.parse(bill_list_json)
  end

  def take_status_census
    census = Hash.new()
    @bills.each do |billparms|
      bill = CatoBill.new(billparms)
      if census[bill.stage].nil?
        census[bill.stage] = 1
      else
        census[bill.stage] = census[bill.stage] + 1
      end
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
    my_year = my_year -1 if my_year.odd?
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
    extract_meta
  end

  # pull bill via Cato API
  def fetch_bill
    params = "billnumber=#{@catonum}&billversion=#{@version}&congress=#{@congress}&billtype=#{@type}"
    begin
      bill_uri = URI(BILL_API_PREFIX + params)
      bill_json = Net::HTTP.get(bill_uri)
      unless bill_json
        raise "Cato bill fetch failed for bill number #{@catonum}"
      end
    rescue Exception => e
      $stderr.puts e.message
      $stderr.puts e.backtrace.inspect
    end
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
    @stage = @doc.xpath("//#{@genre}").attr(stageattr).content
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
f.take_status_census
puts "done"
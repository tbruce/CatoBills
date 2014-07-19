require 'json'
require 'nokogiri'
require 'net/http'
require 'trollop'
require 'rdf'
include RDF

BILL_LIST_URL = 'http://deepbills.cato.org/api/1/bills'
BILL_API_PREFIX = 'http://deepbills.cato.org/api/1/bill?'

# Factory class for Cato bills
class CatoBillFactory
  def initialize
    @bills = Hash.new()
    @cong_num = calc_Congress()
    fetch_bill_list
    puts "checkpoint"
  end

  # get the Cato bill list and rubify
  def fetch_bill_list
    begin
      bill_uri = URI(BILL_LIST_URL)
      bill_json = Net::HTTP.get(bill_uri)
      unless bill_json
        raise "Cato bill list unavailable from Cato server"
      end
    rescue Exception => e
      $stderr.puts e.message
      $stderr.puts e.backtrace.inspect
    end
    @bills = JSON.parse(bill_json)
  end

  def take_status_census
    census = Hash.new()
    @bills.each do |billparms|
      bill = CatoBill.new(billparms)

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
  attr_reader :status
  def initialize (in_bill)
    @bill = in_bill
    @btype = nil
    @status = nil
    @xml = fetch_bill
    extract_meta
  end

  # pull bill via Cato API
  def fetch_bill
    params = "billnumber=#{@bill['billnumber']}&billversion=#{@bill['billversion']}&congress=#{@bill['congress']}&billtype=#{@bill['billtype']}"
    begin
      bill_uri = URI(BILL_API_PREFIX + params)
      billjson = Net::HTTP.get(bill_uri)
      unless billjson
        raise "Cato bill fetch failed for bill number #{bill['billnumber']}"
      end
    rescue Exception => e
      $stderr.puts e.message
      $stderr.puts e.backtrace.inspect
    end
    billhash = JSON.parse(billjson)
    return billhash['billbody']
  end
  def extract_meta
    @doc = Nokogiri::XML(@xml)
    if @bill['billtype'] =~ /res$/
      @btype = 'resolution'
      stageattr = 'resolution-stage'
    end
    if @bill['billtype'] =~ /^(hr|s)$/
      @btype = 'bill'
      stageattr = 'bill-type'
    end


    @status = @doc.at_xpath("//#{@btype}[@='#{stageattr}']")["content"]

    puts "woof"

  end
  def triplify

  end

end

f = CatoBillFactory.new
f.take_status_census
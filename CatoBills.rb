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
    @bills.each do |bill|

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
  def initialize (in_bill)
    @bill = in_bill
    @status = nil
    @xml = fetch_bill(@bill)
    extract_meta
  end

  # pull bill via Cato API
  def fetch_bill
    params = "billnumber=#{bill['billnumber']}&billversion=#{bill['billversion']}&congress=#{bill['congress']}&billtype=#{bill['billtype']}"
    begin
      bill_uri = URI(BILL_API_PREFIX + params)
      xml = Net::HTTP.get(bill_uri)
      unless xml
        raise "Cato bill fetch failed for bill number #{bill['billnumber']}"
      end
    rescue Exception => e
      $stderr.puts e.message
      $stderr.puts e.backtrace.inspect
    end
    return xml
  end
  def extract_meta
    # bill status

  end
  def triplify

  end

end

f = CatoBillFactory.new
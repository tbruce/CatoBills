CATO_ENDPOINT='http://174.129.152.17:8080/openrdf-sesame/repositories/catobills'
##USC_ENDPOINT='http://23.22.254.142:8080/openrdf-sesame/repositories/CFR_structure'   ## wtf?
JSON_ROOT_DIRECTORY='/var/data/json'
CLEANPATH_FILE = '/home/tom/Dropbox/Cato/catobills.cleanpath.whacker.txt'

require 'fileutils'
require 'rdf'
require 'find'
include RDF
require 'sparql'
require 'linkeddata'

class CatoBillsJsonFactory
  def initialize
    @sparql = SPARQL::Client.new(CATO_ENDPOINT)
    #@uscsparql = SPARQL::Client.new(USC_ENDPOINT)
    @json_sparql = SPARQL::Client.new(CATO_ENDPOINT)
    #initialize the directory structure, including killing all the old stuff
    reset_dirs()
    # file to store cleanpaths for cache-whacking
    @cleanpath_file = File.new(CLEANPATH_FILE, 'w')
  end

  # process USC references
  def run
    expansion_list = Array.new
    refquery = <<-EOQUERY
    SELECT DISTINCT ?o
      WHERE {
        {
          ?s <http://liicornell.org/top/refUSCode> ?o
        } UNION {
          ?s <http://liicornell.org/top/refCollection> ?o } .
      }
    EOQUERY
    result = @sparql.query(refquery)
    result.each do |item|
      o = item[:o].to_s

      # it may be a subsection reference.  If so, we need to figure out its parent.
      # given the URI design, we could do that by truncation.  In theory that's dangerous, but in
      # reality the code that creates the triples  creates the URI for the object of the belongsToTransitive
      # property by.... truncation.  So, why not?
      unless o =~ /(chapter|\.\.|etseq|note)/
        o = o.split(/_/)[0..2].join('_')
      end

      # get the JSON for sections, subsections, chapters, subchapters
      do_item(o, o) unless o =~ /\.\./ || o =~ /etseq/

      #if it's a USC chapter or subchapter reference, or a range,  stick it in the list for expansion
      expansion_list.push(o) if o =~ /_chapter_/ #should get chapters and subchapters
      expansion_list.push(o) if o =~ /\.\./ # ranges
      expansion_list.push(o) if o =~ /etseq/ # ranges
    end

    #TODO -- write code for range and chapter/subchapter expansion
    # now run the list of "expandable"  URIs
    #expansion_list.each do |o|
    #  q = "SELECT DISTINCT ?s WHERE { ?s  <http://liicornell.org/liicfr/belongsToTransitive> <#{o}> . }"
    #  result = @uscsparql.query(q)
    #  result.each do |item|
    #    do_item(item[:s].to_s, o)
    #  end
    #end
  end

  def do_item(filename_uri, lookup_uri)
    # construct the path, filename
    myuri = ''
    rootdir = JSON_ROOT_DIRECTORY + '/uscode'
    uristart = 'usc:'
    urimid = '_USC_'
    myprop = 'refUSCode'
    pathprefix = 'uscode'

    parts = filename_uri.split('/')
    cite = parts.pop
    if  cite =~ /_chapter_/
      vol_or_title, midbit, partplc, pg_or_section = cite.split('_')
      cln_pg_or_section = 'chapter-' + pg_or_section
      pg_or_section = 'chapter_' + pg_or_section
    elsif cite =~ /_subchapter_/
      vol_or_title, midbit, partplc, pg_or_section = cite.split('_')
      cln_pg_or_section = 'subchapter-' + pg_or_section
      pg_or_section = 'subchapter_' + pg_or_section
    else
      vol_or_title, midbit, pg_or_section = cite.split('_')
      cln_pg_or_section = pg_or_section.dup unless pg_or_section.nil?    # could be a reference to a full Title
    end

    parentdir = rootdir + '/' + vol_or_title
    mydir = parentdir
    mydir += "/#{pg_or_section}" unless pg_or_section.nil?


    # did we do this one already? we can't be sure without checking, because even though the
    # queries have all returned DISTINCT results, the expansions may overlap in some way
    # and hence create duplicated entries (eg if we have both a subchapter ref and ref to the
    # chapter that contains it)
    return if File.exists?(mydir + '/catobills.json')
    my_cleanpath = "#{pathprefix}/text/#{vol_or_title}"
    my_cleanpath += "/#{cln_pg_or_section}" unless pg_or_section.nil?
    my_cleanpath += "\n"
    @cleanpath_file << my_cleanpath

    Dir.mkdir(parentdir) unless Dir.exist?(parentdir)
    Dir.mkdir(mydir) unless Dir.exist?(mydir)
    myuri = uristart + vol_or_title + urimid
    myuri +=  pg_or_section  unless pg_or_section.nil?

    # get the JSON
    q = <<-EOQ
    PREFIX usc:<http://liicornell.org/id/uscode/>
    PREFIX lii:<http://liicornell.org/top/>
    PREFIX dct:<http://purl.org/dc/terms/>
    SELECT DISTINCT ?title ?page
     WHERE {
       ?bill dct:title ?title .
       ?bill lii:hasPage ?page .
       ?bill lii:refUSCode #{myuri}
      }
    EOQ
    q.rstrip! # looks like heredoc adds whitespace in ruby

    begin
      results = @json_sparql.query(q)
      return if results.empty?    #TODO intercept proposed sections that can cause this
    rescue Exception => e
      $stderr.puts "JSON query blew out for URI #{lookup_uri} :"
      $stderr.puts e.message
      $stderr.puts e.backtrace.inspect
      return
    end

    # write
    $stderr.puts "Creating file #{mydir}/catobills.json \n"
    f = File.new(mydir + '/catobills.json', 'w')
    f << results.to_json
    f.close
  end


# make sure we have the directories we need
  def reset_dirs
    Dir.mkdir(JSON_ROOT_DIRECTORY) unless Dir.exist?(JSON_ROOT_DIRECTORY)
    Dir.mkdir(JSON_ROOT_DIRECTORY + '/uscode') unless Dir.exist?(JSON_ROOT_DIRECTORY + '/uscode')

    Find.find(JSON_ROOT_DIRECTORY) do |path|
      FileUtils.rm_f(path) if path =~ /catobills\.json/
    end
  end

end  # class


factory = CatoBillsJsonFactory.new()
factory.run
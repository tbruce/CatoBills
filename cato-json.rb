CATO_ENDPOINT='http://174.129.152.17:8080/openrdf-sesame/repositories/catobills'
USC_ENDPOINT='http://23.22.254.142:8080/openrdf-sesame/repositories/CFR_structure'   ## wtf?
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
    @uscsparql = SPARQL::Client.new(USC_ENDPOINT)
    @json_sparql = SPARQL::Client.new(CATO_ENDPOINT)
    #initialize the directory structure, including killing all the old stuff
    reset_dirs()
    # file to store cleanpaths for cache-whacking
    @cleanpath_file = File.new(CLEANPATH_FILE, 'w')
  end

  def run
    ['USC'].each do |type|
      run_uri_list(type)
    end
  end

  # processes all cited-to URIs for CFR, US Code, Supreme Court
  def run_uri_list(type)
    expansion_list = Array.new
    case type
      when 'CFR'
        predicate = '<http://liicornell.org/top/refCFR>'
      when 'USC'
        predicate = '<http://liicornell.org/top/refUSCode>'
      when 'SCOTUS'
        predicate = '<http://liicornell.org/top/refSCOTUS>'
    end
    # query
    result = @sparql.query("SELECT DISTINCT ?o WHERE {?s #{predicate} ?o .}")
    result.each do |item|
      o = item[:o].to_s
      # cleanup of bad USC URIs from Citationer
      o.gsub!(/_USC_A\._/, '_USC_')

      # get the JSON
      do_item(o, o, type)

      #if it's a CFR part or subpart reference, stick it in the list for expansion
      expansion_list.push(o) if type == 'CFR' && o =~ /_chapter_/
    end

    #run actual URI list
    # now run the list of "expandable"  URIs
    expansion_list.each do |o|
      q = "SELECT DISTINCT ?s WHERE { ?s  <http://liicornell.org/liicfr/belongsToTransitive> <#{o}> . }"
      result = @uscsparql.query(q)
      result.each do |item|
        do_item(item[:s].to_s, o, type)
      end

    end
  end

  def do_item(filename_uri, lookup_uri, type)
    # construct the path, filename
    rootdir = ''
    myprop = ''
    myuri = ''

    case type
      when 'CFR'
        rootdir = JSON_ROOT_DIRECTORY + '/cfr'
        uristart = 'cfr:'
        urimid = '_CFR_'
        myprop = 'refCFR'
        pathprefix = 'cfr'
      when 'USC'
        rootdir = JSON_ROOT_DIRECTORY + '/uscode'
        uristart = 'usc:'
        urimid = '_USC_'
        myprop = 'refUSCode'
        pathprefix = 'uscode'
      when 'SCOTUS'
        rootdir = JSON_ROOT_DIRECTORY + '/supremecourt'
        uristart = 'scotus:'
        urimid = '_US_'
        myprop = 'refSCOTUS'
        pathprefix = 'supremecourt'
    end
    parts = filename_uri.split('/')
    cite = parts.pop
    if type == 'USC' && cite =~ /_chapter_/
      vol_or_title, midbit, partplc, pg_or_section = cite.split('_')
      cln_pg_or_section = 'chapter-' + pg_or_section
      pg_or_section = 'chapter_' + pg_or_section
    elsif type == 'USC' && cite =~ /_subchapter_/
      vol_or_title, midbit, partplc, pg_or_section = cite.split('_')
      cln_pg_or_section = 'subchapter-' + pg_or_section
      pg_or_section = 'subchapter_' + pg_or_section
    else
      vol_or_title, midbit, pg_or_section = cite.split('_')
      cln_pg_or_section = pg_or_section.dup
    end

    parentdir = rootdir + '/' + vol_or_title
    mydir = parentdir + '/' + pg_or_section

    # did we do this one already?
    return if File.exists?(mydir + '/catobills.json')

    @cleanpath_file <<  "#{pathprefix}/text/#{vol_or_title}/#{cln_pg_or_section}\n"

    Dir.mkdir(parentdir) unless Dir.exist?(parentdir)
    Dir.mkdir(mydir) unless Dir.exist?(mydir)
    myuri = uristart + vol_or_title + urimid + pg_or_section

    # get the JSON
    q = <<EOQ
     PREFIX rdfs:<http://www.w3.org/2000/01/rdf-schema#>
     PREFIX owl:<http://www.w3.org/2002/07/owl#>
     PREFIX xsd:<http://www.w3.org/2001/XMLSchema#>
     PREFIX rdf:<http://www.w3.org/1999/02/22-rdf-syntax-ns#>
     PREFIX xml:<http://www.w3.org/XML/1998/namespace>
     PREFIX skos:<http://www.w3.org/2004/02/skos/core#>
     PREFIX dct:<http://purl.org/dc/terms/>
     PREFIX usc:<http://liicornell.org/id/uscode/>
     PREFIX foaf: <http://xmlns.com/foaf/0.1/>


     SELECT DISTINCT ?title ?page
     WHERE {
       ?bill dct:title ?title .
       ?bill foaf:page ?page .
       ?author foaf:name ?authname .
       ?author scholar:institutionBio ?biolink .
       OPTIONAL { ?author owl:sameAs ?dbpsame FILTER regex (str(?dbpsame),'dbpedia', 'i')}
       ?work dct:contributor ?author
       FILTER regex (str(?author),'scholars','i') .
           {
               SELECT ?work
               WHERE { ?work scholar:
EOQ
    q.rstrip! # looks like heredoc adds whitespace in ruby
    q = q + myprop
    q = q + ' '
    q = q + "<#{lookup_uri}>"
    q = q + ' . } } }'
    begin
      results = @json_sparql.query(q)
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

    Dir.mkdir(JSON_ROOT_DIRECTORY + '/cfr') unless Dir.exist?(JSON_ROOT_DIRECTORY + '/cfr')
    Dir.mkdir(JSON_ROOT_DIRECTORY + '/uscode') unless Dir.exist?(JSON_ROOT_DIRECTORY + '/uscode')
    Dir.mkdir(JSON_ROOT_DIRECTORY + '/supremecourt') unless Dir.exist?(JSON_ROOT_DIRECTORY + '/supremecourt')

    Find.find(JSON_ROOT_DIRECTORY) do |path|
      FileUtils.rm_f(path) if path =~ /catobills\.json/
    end

  end

end


factory = CatoBillsJsonFactory.new()
factory.run
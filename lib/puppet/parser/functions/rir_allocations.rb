require 'net/http'
require 'tmpdir'
require 'yaml'
require 'resolv'

module Puppet::Parser::Functions
  newfunction(:rir_allocations, :type => :rvalue, :doc => <<-'ENDHEREDOC') do |args|
    
    Returns IP ranges allocated to the various Regional Internet Registries
    around the world by type (ipv4 vs ipv6) and their geographical country
    assignment.

    This function is very usefu as a replacement for GeoIP modules as instead
    of requiring per-app support, you can simply use Puppet to take the output
    from this function and generate the designed configuration or ACLs.

    As the data from the RIRs only gets updated daily, this function caches the
    results and only refreshes every 24 hours. If a refresh fails (eg network
    issue) it falls back to serving stale cache so there's no sudden change of
    configuration as long as the cache files remain on disk (generally in /tmp)

    Note that unlike a GeoIP provider there's no curation taking place, we
    assume the country an IP range has been allocated to, is where it is being
    used - but this is not always true, so your milage may vary.

    The registries are:
    AFRNIC    : Africa Region
    APNIC     : Asia/Pacific Region
    ARIN      : North America Region
    LACNIC    : Latin America and some Caribbean Islands
    RIPE NCC  : Europe, the Middle East, and Central Asia
    ENDHEREDOC


    # RIRs & their data
    rirs = { 'afrinic'  => 'http://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-latest',
             'apnic'    => 'http://ftp.apnic.net/stats/apnic/delegated-apnic-latest',
             'arin'     => 'http://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest',
             'lacnic'   => ' http://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-latest',
             'ripe-ncc' => 'http://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-latest'
    }

    # Make sure an RIR is selected (Mandatory) and that it is valid.
    unless args[0] == nil
      selected_rir = args[0].downcase

      if rirs[selected_rir] == nil
        raise Puppet::ParseError, 'You must select an RIR to return ranges for EG: rir_allocations(\'apnic\', \'ipv6\')'
      end
    else
      raise Puppet::ParseError, 'You must select an RIR to return ranges for EG: rir_allocations(\'apnic\', \'ipv6\')'
    end

    unless args[1] == nil
      selected_inet = args[1].downcase

      if selected_inet != 'ipv4' and selected_inet != 'ipv6'
        raise Puppet::ParseError, 'You must select either IPv4 or IPv6 to return ranges for EG: rir_allocations(\'apnic\', \'ipv6\')'
      end
    else
      raise Puppet::ParseError, 'You must select either IPv4 or IPv6 to return ranges for EG: rir_allocations(\'apnic\', \'ipv6\')'
    end

    unless args[2] == nil
      selected_country = args[2].upcase
      
      unless selected_country.match(/^[A-Z]{2}$/)
        raise Puppet::ParseError, 'Country is optional and must be a 2char upper case code. EG: rir_allocations(\'apnic\', \'ipv6\', \'NZ\')'
      end
    else
      # Country is the only optional
      selected_country = nil
    end


    # Run through each registry and add it to the output
    debug("RIR: Processing data for RIR "+ selected_rir)

    data_cached      = nil
    data_downloaded  = nil
    data_expired     = true

    # Do we have a processed copy of the data cached on disk?
    # TODO: Is there some better "puppet way" of caching this? Couldn't find
    # any clear advice when researching and can't see an obvious home for 
    # function caches. :-/ PRs welcome if you have a better idea.

    cachefile = Dir.tmpdir() + "/.puppet_rir_allocations_" + selected_rir +".yaml"

    if File.exists?(cachefile)
      debug("RIR: Loading RIR data from cachefile "+ cachefile +"...")

      # Load the data
      begin
        data_cached = YAML::load(File.open(cachefile))
      rescue StandardError => e
        raise Puppet::ParseError, "Unexpected error attempting to load cache file "+ cachefile +" exception "+ e.class.to_s
      end

      # Check if file has expired?
      if (Time.now - File.stat(cachefile).mtime).to_i <= 86400
        # Anything less than a day old is still fresh. Note that the RIRs
        # don't update more than once a day, so no point expiring any more
        # frequently than that.
        data_expired = false
      end
    end


    # Do we need to download and parse new data?
    if data_expired or data_cached.nil?
      # Either of two conditions is true:
      
      begin
        tries ||= 3


        # TODO: Each regional registry has their own mirror, would be smart to
        # make this fact retry different ones if a particular one fails.
        uri = URI(rirs[selected_rir])
        debug("RIR: Downloading latest data... " + uri.to_s)
        response = Net::HTTP.get_response(uri)

       if response.code.to_i == 200

         # We have our data, we now need to process file. Format is defined as per:
         # https://www.apnic.net/publications/media-library/documents/resource-guidelines/rir-statistics-exchange-format
         data_downloaded         = Hash.new
         data_downloaded["ipv4"] = Hash.new {|h,k| h[k] = Array.new }
         data_downloaded["ipv6"] = Hash.new {|h,k| h[k] = Array.new }

         response.body.each_line do |line|

           # IPv4, example:
           # apnic|AU|ipv4|1.0.0.0|256|20110811|assigned
           if matches = line.match(/^\w*\|([A-Z]{2})\|ipv4\|([0-9\.]*)\|([0-9]*)\|/)

             # IPv4 records don't supply CIDR notation, instead we have the number of
             # hosts, which we can calcuate the CIDR from.
             cidr_map = { 16777216 => 8,  8388608 => 9,  4194304 => 10, 2097152 => 11, 1048576 => 12,
                          524288   => 13, 262144  => 14, 131072  => 15, 65536   => 16, 32768   => 17,
                          16384    => 18, 8192    => 19, 4096    => 20, 2048    => 21, 1024    => 22,
                          512      => 23, 256     => 24, 128     => 25, 64      => 26, 32      => 27,
                          16       => 28, 8       => 29, 4       => 30, 2       => 31, 0       => 32 }

             if defined? cidr_map[ matches[3].to_i ]
               # We can trust the CIDR, but make sure the IP address is valid
               if (matches[2] =~ Resolv::IPv4::Regex ? true : false)
                 data_downloaded['ipv4'][ matches[1] ].push matches[2] +"/"+ cidr_map[ matches[3].to_i ].to_s
               else
                 debug("RIR: IPv4 address "+ matches[2] +" is invalid and has been skipped")
               end

             else
               # The spec is a little vauge and suggests that the count
               # might not always equal the CIDR subnet size... Let's log
               # anything that doesn't match in debug mode.
               debug("RIR: Unable to determine CIDR of "+ matches[2] +" with "+ matches[1] +" hosts.")
             end

           end

           # IPv6, example:
           # apnic|JP|ipv6|2001:200::|35|19990813|allocated
           if matches = line.match(/^\w*\|([A-Z]{2})\|ipv6\|([0-9A-Fa-f:]*)\|([0-9]*)\|/)

             # Make sure the IP address and CIDR is valid
             if (matches[2] =~ Resolv::IPv6::Regex ? true : false) and matches[3].to_i > 0 and matches[3].to_i < 128
               data_downloaded['ipv6'][ matches[1] ].push matches[2] +"/"+ matches[3]
             else
               debug("RIR: IPv6 address "+ matches[2] +"/"+ matches[3] +" is invalid and has been skipped")
             end
           end

         end
             
          # Write the new cache file
          begin
            debug("RIR: Writing to cache file at "+ cachefile)

            # Make sure the file isn't writable by anyone else
            FileUtils.touch cachefile
            File.chmod(0600, cachefile)

            # Write out the processed data in YAML format
            File.open(cachefile, 'w' ) do |file|
              YAML.dump(data_downloaded, file)
            end

          rescue StandardError => e
            raise Puppet::ParseError, "Unexpected error attempting to write cache file "+ cachefile +" exception "+ e.class.to_s
          end

       else
         raise Puppet::ParseError, "Unexpected response code: "+ response.code
       end

      rescue StandardError => e
        retry unless (tries -= 1).zero?

        # We've been unable to download a new file. If there's no cached data available, we should return an error.
        if data_cached.nil?
          raise Puppet::ParseError, "Unexpected error fetching delegated ranges for registry (" + selected_rir +") unexpected exception "+ e.class.to_s
          return nil
        end

      end
    end

    # If we have downloaded data use that, otherwise we use the cached data.
    unless data_downloaded.nil?
      data = data_downloaded
    else
      data = data_cached
    end

    # Catch the developer being a muppet, this should never be possible to execute.
    if data.to_s.empty?
      raise Puppet::ParseError, "Something went very wrong with rir_allocations function"
      return nil
    end

    # Complete!
    debug("RIR: RIR data processed, returning results")

    if selected_country == nil
      # Hash of countries containing arrays of addresses
      return data[selected_inet]
    else
      # Array of addresses
      return data[selected_inet][selected_country]
    end

  end
 
end

# vim: ai ts=2 sts=2 et sw=2 ft=ruby

# puppet-rirs

Provides custom Puppet functions that allow lookup of data provided by Regional
Internet Registries such as IP allocations, useful for purposes like generating
geographical IP Access Control Lists (essentially GeoIP rules).

Currently we have the one function (rir_allocations) but additional functions
or facts could always be added in future such as AS numbers if desired.

If you are not familar with the different RIRs, they exist to manage the
allocation and registration of internet number resources. There are 5 RIRs
which cover different regions:

| Registry | Region                                    |
|----------|-------------------------------------------|
| AFRNIC   | Africa Region                             |
| APNIC    | Asia/Pacific Region                       |
| ARIN     | North America Region                      |
| LACNIC   | Latin America and some Caribbean Islands  |
| RIPE NCC | Europe, the Middle East, and Central Asia |



# rir_allocations (registry, inet, country)

Returns IP ranges allocated to the various Regional Internet Registries
around the world by type (ipv4 vs ipv6) and their geographical country
assignment.

This function is very useful as a replacement for GeoIP modules as instead
of requiring per-app support, you can simply use Puppet to take the output
from this function and generate the designed configuration or ACLs.

As the data from the RIRs only gets updated daily, this function caches the
results and only refreshes every 24 hours. If a refresh fails (eg network
issue) it falls back to serving stale cache so there's no sudden change of
configuration as long as the cache files remain on disk (generally in /tmp)

Note that unlike a GeoIP provider there's no curation taking place, we
assume the country an IP range has been allocated to, is where it is being
used - but this is not always true, so your milage may vary.


## Parameters & Output

| Parameter  | Values                                          |
|------------|-------------------------------------------------|
| registry   | One of: afrnic, apnic, arin, lacnic, ripe-ncc   |
| inet       | Either: ipv4 or ipv6                            |
| country    | Optional: Filter to a particular 2-char country |


The function returns either two different outputs. If a country code has NOT
been supplied, it returns a hash of countries with an array of IP addresses
for each country.

If a country code HAS been supplied, it returns an array of all the IP
addresses allocated to that country.

Return format of addresses is always IP/CIDR for both IPv4 and IPv6.


## Usage Examples

You can call the rir_allocations function from inside your Puppet manifests and
even iterate through them inside Puppet's DSL, or you can use it directly from
ERB templates.


### Usage in Puppet Resources

This is an example of setting iptables rules that restrict traffic to SSH to
New Zealand (APNIC/NZ) IPv6 addresses using the puppetlabs/firewall module 
with ip6tables provider for Linux:

    # Use jethrocarr-rirs rir_allocations function to get an array of all IP
    # addresses belonging to NZ IPv6 allocations and then create iptables
    # rules for each of them accordingly.
    #
    # Note we use a old style interation (pre future parser) to ensure
    # compatibility with Puppet 3 systems. In future when 4.x+ is standard we
    # could rewite with a newer loop approach as per:
    # https://docs.puppetlabs.com/puppet/latest/reference/lang_iteration.html

    define s_firewall::ssh_ipv6 ($address = $title) {
      firewall { "004 V6 Permit SSH ${address}":
        provider => 'ip6tables',
        proto    => 'tcp',
        port     => '22',
        source   => $address,
        action   => 'accept',
      }  
    }

    $ipv6_allocations = rir_allocations('apnic', 'ipv6', 'nz')
    s_firewall::pre::ssh_ipv6 { $ipv6_allocations: }

Note that due to the use of Puppet 3 compatible iterator, you'll need to rename
`s_firewall::ssh_ipv6` to `yourmodule::yourclass::ssh_ipv6` as the
definition has to be a child of the module/class that it's inside of - in the
above example, it lives in `s_firewall/manifests/init.pp`.

This example isn't the best, since the [puppetlabs-firewall](https://github.com/puppetlabs/puppetlabs-firewall)
module is extremely inefficent and can take hours to generate a large GeoIP
ruleset on a small server.

If you run into this sort of issue, my companion module
[jethrocarr-speedychains](https://github.com/jethrocarr/puppet-speedychains#geoip-example)
offers a solution that works nicely with this module to generate thousands of
lines of rules in just seconds.


### Usage in Puppet ERB Templates

If you want to provide the list of addresses to configuration files or scripts
rather than using it to create Puppet resources, it's entirely possible to call
the function directly from inside ERB templates. The following is an example of
generating Apache `mod_access_compat` rules to restrict visitors from
New Zealand (APNIC/NZ) IPv4 and IPv6 addresses only.

    <Location "/admin">
      Order deny,allow
      Deny from all

      # Use the jethrocarr-rirs Puppet module functions to lookup the IP
      # allocations from APNIC for New Zealand. This works better than the
      # buggy mod_geoip module since it supports both IPv4 and IPv6 concurrently.

      <% scope.function_rir_allocations(['apnic', 'ipv4', 'nz']).each do |ipv4| -%>
        Allow from <%= ipv4 %>
      <% end -%>
      <% scope.function_rir_allocations(['apnic', 'ipv6', 'nz']).each do |ipv6| -%>
        Allow from <%= ipv6 %>
      <% end -%>
    </Location>

Remember the larger registries and countries can have thousands of address
allocations, make sure you know the impact of generating so many rules in your
application configurations.


# Requirements

The minimum requirements are met by most systems:
* Standard Ruby environment.
* Ability to connect to remote HTTP webservers to download latest data.

However a big performance improvement can be made by installing the netaddr
third party Gem. This will slow down the initial run of the function
considerably, but it performs a merge of all consecutive ranges returned
per-country which means far smaller output being fed into Puppet resources or
configuration files. For example, APNIC's entire v4 and v6 allocation is around
33k records unmerged vs 24k when merged by country.

If you're planning to use this function to generate resources such as iptables
firewall policies, you almost certainly want to install netaddr:

    gem install netaddr

If the gem is not installed, the merge process is skipped over but a notice is
added to the Puppet master logs reminding/recommending the installation of
netaddr for everyone whom didn't read this README.md like you did. :-)


# Development

Contributions via the form of Pull Requests is always welcome!

## Nice to have features

General improvements to existing logic are always good, but additional
functions or facts relating to RIR-sourced data is also welcome. Some ideas:

1. Pulling AS numbers could potentially be useful at some point for people
   running networks.

2. Automated testing contributions welcome, Puppet's documentation on doing
   tests with custom functions is a bit lacking and the default Puppet module
   creation stuff doesn't setup any useful tests other than ensuring it's valid
   Ruby.


Just remember that:

1. It is important not to break the existing parameter options and output of
   existing functions due to impact it could have on systems, please keep this
   in mind when filing PRs.

2. The use of third party Gems must have a graceful fall-back if they are not
   available on the user's environment. Puppet won't automatically install
   dependencies for them sadly.


## Debugging

Remember that custom Puppet functions execute on the master/server, not the
local server. This means that:

1. If the master is behind a restrictive network it may be unable to access the
different RIR servers to download the latest data.

2. Errors and debug log messages might only appear on the master.

If Puppet is run with --debug it exposes additional debug messages from the RIR
functions, useful if debugging timeout issues, etc.

    Debug: Scope(Class[main]): RIR: Processing data for RIR apnic
    Debug: Scope(Class[main]): RIR: Downloading latest data... http://ftp.apnic.net/stats/apnic/delegated-apnic-latest
    Debug: Scope(Class[main]): RIR: Performing a merge of the returned ranges per-country
    Debug: Scope(Class[main]): RIR: Writing to cache file at /tmp/.puppet_rir_allocations_apnic.yaml
    Debug: Scope(Class[main]): RIR: RIR data processed, returning results
    Debug: Scope(Class[main]): RIR: Processing data for RIR apnic
    Debug: Scope(Class[main]): RIR: Loading RIR data from cachefile /tmp/.puppet_rir_allocations_apnic.yaml...
    Debug: Scope(Class[main]): RIR: RIR data processed, returning results


# License

This module is licensed under the Apache License, Version 2.0 (the "License").
See the `LICENSE` or http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

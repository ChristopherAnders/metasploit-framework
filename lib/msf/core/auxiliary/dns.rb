# -*- coding: binary -*-
module Msf

###
#
# This module provides methods for implementing DNS stuff
#
###
module Auxiliary::Dns

  def initialize(info = {})
    super
    register_options(
      [
        OptAddress.new('NS', [false, 'Specify the nameserver to use for queries (default is system DNS)'])
      ]
    )

    register_advanced_options(
      [
        OptBool.new('DNS_NOTE', [false, 'Save all DNS result into the notes (default: true)', true]),
        OptInt.new('DNS_RETRY', [false, 'Number of times to try to resolve a record if no response is received', 2]),
        OptInt.new('DNS_RETRY_INTERVAL', [false, 'Number of seconds to wait before doing a retry', 2]),
        OptBool.new('DNS_TCP', [false, 'Run queries over TCP', false]),
        OptInt.new('DNS_TIMEOUT', [false, 'DNS TIMEOUT', 8])
      ]
    )
  end

  def dns_axfr(domain)
    nameservers = dns_get_ns(domain)
    return if nameservers.blank?
    records = []
    nameservers.each do |nameserver|
      next if nameserver.blank?
      print_status("Attempting DNS AXFR for #{domain} from #{nameserver}")
      dns = Net::DNS::Resolver.new
      dns.use_tcp = datastore['DNS_TCP']
      dns.udp_timeout = datastore['DNS_TIMEOUT']
      dns.retry_number = datastore['DNS_RETRY']
      dns.retry_interval = datastore['DNS_RETRY_INTERVAL']

      ns_a_records = []
      # try to get A record for nameserver from target NS, which may fail
      target_ns_a = dns_get_a(nameserver, 'DNS AXFR records')
      ns_a_records |= target_ns_a if target_ns_a
      ns_a_records << ::Rex::Socket.resolv_to_dotted(nameserver)
      begin
        dns.nameservers -= dns.nameservers
        dns.nameservers = ns_a_records
        zone = dns.axfr(domain)
      rescue ResolverArgumentError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, ::NoResponseError, ::Timeout::Error => e
        print_error("Query #{domain} DNS AXFR - exception: #{e}")
      end
      next if zone.blank?
      records << zone
      print_good("#{domain} Zone Transfer: #{zone}")
    end
    return if records.blank?
    dns_note(domain, 'DNS AXFR recods', records) if datastore['DNS_NOTE']
    records
  end

  def dns_bruteforce(domain, wordlist, threads)
    return if wordlist.blank?
    threads = 1 if threads <= 0

    queue = []
    File.foreach(wordlist) do |line|
      queue << "#{line.chomp}.#{domain}"
    end

    records = []
    until queue.empty?
      t = []
      threads = 1 if threads <= 0

      if queue.length < threads
        # work around issue where threads not created as the queue isn't large enough
        threads = queue.length
      end

      begin
        1.upto(threads) do
          t << framework.threads.spawn("Module(#{refname})", false, queue.shift) do |test_current|
            Thread.current.kill unless test_current
            a = dns_get_a(test_current, 'DNS bruteforce records', true)
            records |= a if a
          end
        end
        t.map(&:join)

      rescue ::Timeout::Error
      ensure
        t.each { |x| x.kill rescue nil }
      end
    end
    records
  end

  def dns_get_a(domain, type='DNS A records', displayed=false)
    resp = dns_query(domain, 'A')
    return if resp.blank? || resp.answer.blank?

    records = []
    resp.answer.each do |r|
      next unless r.class == Net::DNS::RR::A
      records << r.address.to_s
      print_good("#{domain} A: #{r.address} ") if displayed
    end
    return if records.blank?
    dns_note(domain, type, records) if datastore['DNS_NOTE']
    records
  end

  def dns_get_cname(domain)
    print_status("querying DNS CNAME records for #{domain}")
    resp = dns_query(domain, 'CNAME')
    return if resp.blank? || resp.answer.blank?

    records = []
    resp.answer.each do |r|
      next unless r.class == Net::DNS::RR::CNAME
      records << r.cname.to_s
      print_good("#{domain} CNAME: #{r.cname}")
    end
    return if records.blank?
    dns_note(domain, 'DNS CNAME records', records) if datastore['DNS_NOTE']
    records
  end

  def dns_get_mx(domain)
    print_status("querying DNS MX records for #{domain}")
    begin
      resp = dns_query(domain, 'MX')
      return if resp.blank? || resp.answer.blank?

      records = []
      resp.answer.each do |r|
        next unless r.class == Net::DNS::RR::MX
        records << r.exchange.to_s
        print_good("#{domain} MX: #{r.exchange}")
      end
    rescue SocketError => e
      print_error("Query #{domain} DNS MX - exception: #{e}")
    ensure
      return if records.blank?
      dns_note(domain, 'DNS MX records', records) if datastore['DNS_NOTE']
      records
    end
  end

  def dns_get_ns(domain)
    print_status("querying DNS NS records for #{domain}")
    resp = dns_query(domain, 'NS')
    return if resp.blank? || resp.answer.blank?

    records = []
    resp.answer.each do |r|
      next unless r.class == Net::DNS::RR::NS
      records << r.nsdname.to_s
      print_good("#{domain} NS: #{r.nsdname}")
    end
    return if records.blank?
    dns_note(domain, 'DNS NS records', records) if datastore['DNS_NOTE']
    records
  end

  def dns_get_ptr(ip)
    resp = dns_query(ip, nil)
    return if resp.blank? || resp.answer.blank?

    records = []
    resp.answer.each do |r|
      next unless r.class == Net::DNS::RR::PTR
      records << r.ptr.to_s
      print_good("#{ip}: PTR: #{r.ptr} ")
    end
    return if records.blank?
    dns_note(ip, 'DNS PTR records', records) if datastore['DNS_NOTE']
    records
  end

  def dns_get_soa(domain)
    print_status("querying DNS SOA records for #{domain}")
    resp = dns_query(domain, 'SOA')
    return if resp.blank? || resp.answer.blank?

    records = []
    resp.answer.each do |r|
      next unless r.class == Net::DNS::RR::SOA
      records << r.mname.to_s
      print_good("#{domain} SOA: #{r.mname}")
    end
    return if records.blank?
    dns_note(domain, 'DNS SOA records', records) if datastore['DNS_NOTE']
    records
  end

  def dns_get_srv(domain)
    print_status("querying DNS SRV records for #{domain}")
    srv_protos = %w(tcp udp tls)
    srv_record_types = %w(
      gc kerberos ldap test sips sip aix finger ftp http
      nntp telnet whois h323cs h323be h323ls sipinternal sipinternaltls
      sipfederationtls jabber jabber-client jabber-server xmpp-server xmpp-client
      imap certificates crls pgpkeys pgprevokations cmp svcp crl oscp pkixrep
      smtp hkp hkps)

    srv_records_data = []
    srv_record_types.each do |srv_record_type|
      srv_protos.each do |srv_proto|
        srv_record = "_#{srv_record_type}._#{srv_proto}.#{domain}"
        resp = dns_query(srv_record, Net::DNS::SRV)
        next if resp.blank? || resp.answer.blank?
        srv_record_data = []
        resp.answer.each do |r|
          next if r.type == Net::DNS::RR::CNAME
          host = r.host.gsub(/\.$/, '')
          data = {
            host: host,
            port: r.port,
            priority: r.priority
          }
          print_good("#{srv_record} SRV: #{data}")
          srv_record_data << data
        end
        if datastore['DNS_NOTE']
          srv_records_data << {
            srv_record => srv_record_data
          }
          report_note(
            type: srv_record,
            data: srv_record_data
          )
        end
      end
    end
    return if srv_records_data.empty?
  end

  # https://data.iana.org/TLD/
  def dns_get_tld(domain, wordlist_tld = '')
    begin
      print_status("querying DNS TLD records for #{domain}")
      domain_ = domain.split('.')
      domain_.pop
      domain_ = domain_.join('.')

      tlds = []
      if wordlist_tld.blank?
        tlds = [
          'com', 'org', 'net', 'edu', 'mil', 'gov', 'uk', 'af', 'al', 'dz',
          'as', 'ad', 'ao', 'ai', 'aq', 'ag', 'ar', 'am', 'aw', 'ac', 'au',
          'at', 'az', 'bs', 'bh', 'bd', 'bb', 'by', 'be', 'bz', 'bj', 'bm',
          'bt', 'bo', 'ba', 'bw', 'bv', 'br', 'io', 'bn', 'bg', 'bf', 'bi',
          'kh', 'cm', 'ca', 'cv', 'ky', 'cf', 'td', 'cl', 'cn', 'cx', 'cc',
          'co', 'km', 'cd', 'cg', 'ck', 'cr', 'ci', 'hr', 'cu', 'cy', 'cz',
          'dk', 'dj', 'dm', 'do', 'tp', 'ec', 'eg', 'sv', 'gq', 'er', 'ee',
          'et', 'fk', 'fo', 'fj', 'fi', 'fr', 'gf', 'pf', 'tf', 'ga', 'gm',
          'ge', 'de', 'gh', 'gi', 'gr', 'gl', 'gd', 'gp', 'gu', 'gt', 'gg',
          'gn', 'gw', 'gy', 'ht', 'hm', 'va', 'hn', 'hk', 'hu', 'is', 'in',
          'id', 'ir', 'iq', 'ie', 'im', 'il', 'it', 'jm', 'jp', 'je', 'jo',
          'kz', 'ke', 'ki', 'kp', 'kr', 'kw', 'kg', 'la', 'lv', 'lb', 'ls',
          'lr', 'ly', 'li', 'lt', 'lu', 'mo', 'mk', 'mg', 'mw', 'my', 'mv',
          'ml', 'mt', 'mh', 'mq', 'mr', 'mu', 'yt', 'mx', 'fm', 'md', 'mc',
          'mn', 'ms', 'ma', 'mz', 'mm', 'na', 'nr', 'np', 'nl', 'an', 'nc',
          'nz', 'ni', 'ne', 'ng', 'nu', 'nf', 'mp', 'no', 'om', 'pk', 'pw',
          'pa', 'pg', 'py', 'pe', 'ph', 'pn', 'pl', 'pt', 'pr', 'qa', 're',
          'ro', 'ru', 'rw', 'kn', 'lc', 'vc', 'ws', 'sm', 'st', 'sa', 'sn',
          'sc', 'sl', 'sg', 'sk', 'si', 'sb', 'so', 'za', 'gz', 'es', 'lk',
          'sh', 'pm', 'sd', 'sr', 'sj', 'sz', 'se', 'ch', 'sy', 'tw', 'tj',
          'tz', 'th', 'tg', 'tk', 'to', 'tt', 'tn', 'tr', 'tm', 'tc', 'tv',
          'ug', 'ua', 'ae', 'gb', 'us', 'um', 'uy', 'uz', 'vu', 've', 'vn',
          'vg', 'vi', 'wf', 'eh', 'ye', 'yu', 'za', 'zr', 'zm', 'zw', 'int',
          'gs', 'info', 'biz', 'su', 'name', 'coop', 'aero'
        ]
      else
        File.foreach(wordlist_tld) do |line|
          tlds << line.downcase.chomp
        end
      end

      records = []
      tlds.each do |tld|
        tldr = dns_get_a("#{domain_}.#{tld}", 'DNS TLD records')
        next if tldr.blank?
        records |= tldr
        print_good("#{domain_}.#{tld}: TLD: #{tldr.join(',')}")
      end
    rescue ArgumentError => e
      print_error("Query #{domain} DNS TLD - exception: #{e}")
    ensure
      return if records.blank?
      records
    end
  end

  def dns_get_txt(domain)
    print_status("querying DNS TXT records for #{domain}")
    resp = dns_query(domain, 'TXT')
    return if resp.blank? || resp.answer.blank?

    records = []
    resp.answer.each do |r|
      next unless r.class == Net::DNS::RR::TXT
      records << r.txt.to_s
      print_good("#{domain} TXT: #{r.txt}")
    end
    return if records.blank?
    dns_note(domain, 'DNS TXT records', records) if datastore['DNS_NOTE']
    records
  end

  def dns_query(domain, type)
    begin
      nameserver = datastore['NS']
      if nameserver.blank?
        dns = Net::DNS::Resolver.new
      else
        dns = Net::DNS::Resolver.new(nameservers: ::Rex::Socket.resolv_to_dotted(nameserver))
      end
      dns.use_tcp = datastore['DNS_TCP']
      dns.udp_timeout = datastore['DNS_TIMEOUT']
      dns.retry_number = datastore['DNS_RETRY']
      dns.retry_interval = datastore['DNS_RETRY_INTERVAL']
      dns.query(domain, type)
    rescue ResolverArgumentError, Errno::ETIMEDOUT, ::NoResponseError, ::Timeout::Error => e
      print_error("Query #{domain} DNS #{type} - exception: #{e}")
      return nil
    end
  end

  def dns_note(target, type, records)
    data = { 'target' => target, 'records' => records }
    report_note(host: target, sname: 'dns', type: type, data: data, update: :unique_data)
  end

  def dns_reverse(cidr, threads)
    unless cidr
      print_error 'ENUM_RVL enabled, but no IPRANGE specified'
      return
    end

    iplst = []
    ipadd = Rex::Socket::RangeWalker.new(cidr)
    numip = ipadd.num_ips
    while iplst.length < numip
      ipa = ipadd.next_ip
      break unless ipa
      iplst << ipa
    end

    records = []
    while !iplst.nil? && !iplst.empty?
      t = []
      threads = 1 if threads <= 0
      begin
        1.upto(threads) do
          t << framework.threads.spawn("Module(#{refname})", false, iplst.shift) do |ip_text|
            next if ip_text.nil?
            a = dns_get_ptr(ip_text)
            records |= a if a
          end
        end
        t.map(&:join)

      rescue ::Timeout::Error
      ensure
        t.each { |x| x.kill rescue nil }
      end
    end
    records
  end

  def dns_wildcard_enabled?(domain)
    records = dns_get_a("#{Rex::Text.rand_text_alpha(16)}.#{domain}", 'DNS wildcard records')
    if records.blank?
      false
    else
      print_warning('dns wildcard is enable OR fake dns server')
      true
    end
  end

end
end

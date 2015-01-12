confine :to, :masterless => false

require 'puppet/acceptance/common_utils'
extend Puppet::Acceptance::CAUtils
require 'puppet/acceptance/classifier_utils'
extend Puppet::Acceptance::ClassifierUtils

disable_pe_enterprise_mcollective_agent_classes

test_name "autosign command and csr attributes behavior (#7243,#7244)" do

  def assert_key_generated(name)
    assert_match(/Creating a new SSL key for #{name}/, stdout, "Expected agent to create a new SSL key for autosigning")
  end

  testdirs = {}
  test_certnames = []

  step "Generate tmp dirs on all hosts" do
    hosts.each do |host|
      testdirs[host] = host.tmpdir('autosign_command')
      on(host, "chmod 755 #{testdirs[host]}")
    end
  end

  teardown do
    step "clear test certs"
    test_certnames.each do |cn|
      on(master, puppet("cert", "clean", cn), :acceptable_exit_codes => [0,24])
    end
  end

  hostname = master.execute('facter hostname')
  fqdn = master.execute('facter fqdn')

  step "Step 1: ensure autosign command can approve CSRs" do
    master_opts = {
      'master' => {
        'autosign' => '/bin/true',
        'dns_alt_names' => "puppet,#{hostname},#{fqdn}",
      }
    }
    with_puppet_running_on(master, master_opts) do
      agents.each do |agent|
        next if agent == master

        test_certnames << (certname = "#{agent}-autosign")
        on(agent, puppet("agent --test",
                  "--server #{master}",
                  "--waitforcert 0",
                  "--ssldir", "'#{testdirs[agent]}/ssldir-autosign'",
                  "--certname #{certname}"), :acceptable_exit_codes => [0,2])
        assert_key_generated(agent)
        assert_match(/Caching certificate for #{agent}/, stdout, "Expected certificate to be autosigned")
      end
    end
  end

  step "Step 2: ensure autosign command can reject CSRs" do
    master_opts = {
      'master' => {
        'autosign' => '/bin/false',
        'dns_alt_names' => "puppet,#{hostname},#{fqdn}",
      }
    }
    with_puppet_running_on(master, master_opts) do
      agents.each do |agent|
        next if agent == master

        test_certnames << (certname = "#{agent}-reject")
        on(agent, puppet("agent --test",
                        "--server #{master}",
                        "--waitforcert 0",
                        "--ssldir", "'#{testdirs[agent]}/ssldir-reject'",
                        "--certname #{certname}"), :acceptable_exit_codes => [1])
        assert_key_generated(agent)
        assert_match(/no certificate found/, stdout, "Expected certificate to not be autosigned")
      end
    end
  end

  autosign_inspect_csr_path = "#{testdirs[master]}/autosign_inspect_csr.rb"
  step "Step 3: setup an autosign command that inspects CSR attributes" do
    autosign_inspect_csr = <<-END
#!/usr/bin/env ruby
require 'openssl'

def unwrap_attr(attr)
  set = attr.value
  str = set.value.first
  str.value
end

csr_text = STDIN.read
csr = OpenSSL::X509::Request.new(csr_text)
passphrase = csr.attributes.find { |a| a.oid == '1.3.6.1.4.1.34380.2.1' }
# And here we jump hoops to unwrap ASN1's Attr Set Str
if unwrap_attr(passphrase) == 'my passphrase'
  exit 0
end
exit 1
    END
    create_remote_file(master, autosign_inspect_csr_path, autosign_inspect_csr)
    on master, "chmod 777 #{testdirs[master]}"
    on master, "chmod 777 #{autosign_inspect_csr_path}"
  end

  agent_csr_attributes = {}
  step "Step 4: create attributes for inclusion on csr on agents" do
    csr_attributes = <<-END
custom_attributes:
  1.3.6.1.4.1.34380.2.0: hostname.domain.com
  1.3.6.1.4.1.34380.2.1: my passphrase
  1.3.6.1.4.1.34380.2.2: # system IPs in hex
    - 0xC0A80001 # 192.168.0.1
    - 0xC0A80101 # 192.168.1.1
    END

    agents.each do |agent|
      agent_csr_attributes[agent] = "#{testdirs[agent]}/csr_attributes.yaml"
      create_remote_file(agent, agent_csr_attributes[agent], csr_attributes)
    end
  end

  step "Step 5: successfully obtain a cert" do
    master_opts = {
      'master' => {
        'autosign' => autosign_inspect_csr_path,
        'dns_alt_names' => "puppet,#{hostname},#{fqdn}",
      },
    }
    with_puppet_running_on(master, master_opts) do
      agents.each do |agent|
        next if agent == master

        step "attempting to obtain cert for #{agent}"
        test_certnames << (certname = "#{agent}-attrs")
        on(agent, puppet("agent --test",
                         "--server #{master}",
                         "--waitforcert 0",
                         "--ssldir", "'#{testdirs[agent]}/ssldir-attrs'",
                         "--csr_attributes '#{agent_csr_attributes[agent]}'",
                         "--certname #{certname}"), :acceptable_exit_codes => [0,2])
        assert_key_generated(agent)
      end
    end
  end
end

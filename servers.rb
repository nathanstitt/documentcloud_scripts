require 'dc/aws'
require 'net/ssh'
require 'socket'
require 'timeout'

Thread.abort_on_exception = true

class Node < Struct.new(:name, :address, :ec2)
  def prefixed?(prefix)
    !name.match(/^#{prefix}/).nil?
  end
  def number
    name[/\d+$/,0].to_i
  end
  def reserved?
    number <= 4
  end
  def ssh_open?
    Timeout::timeout(1) do
      begin
        TCPSocket.new(address, 22).close
        true
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        false
      end
    end
  rescue Timeout::Error
    false
  end

end

class InstanceCollection
  include Enumerable

  def initialize(nodes)
    @nodes=nodes
    @hl = HighLine.new
  end

  def ssh_key
    Rails.root.join('secrets/keys/documentcloud.pem')
  end

  def address_table
    map do |i| sprintf("%-10s %-20s %s",
      i.name,
      i.ec2.private_dns_name.gsub(/.ec2.internal$/,''),
      i.address.gsub(/.compute-1.amazonaws.com$/,'')
    )
    end
  end

  def each(&block)
    @nodes.each(&block)
  end

  def terminate!
    list = "\n\t#{address_table.join("\n\t")}"
    if any? {|i| i.reserved? }
      @hl.say(@hl.color "Nope!#{list}\nare protected!", HighLine::RED)
      return
    end
    if @hl.agree("This will terminate:#{list}\nAre you sure? (Y/N)", true)
      each{ |i| i.ec2.terminate }
    end
  end

  def execute(cmd)
    threads = []
    each do | node |
      threads << Thread.new do
        Net::SSH.start( node.address, 'ubuntu', keys: ssh_key, paranoid: false) do |ssh|
          prefix =<<-EOS.strip_heredoc
          source /usr/local/share/chruby/chruby.sh
          source /usr/local/share/chruby/auto.sh
          cd ~/documentcloud

        EOS
          ssh.exec!(prefix + cmd) do | channel, stream, data |
            color = ( stream == :stdout ? HighLine::GREEN : HighLine::RED )
            data.each_line do | line |
              @hl.say(@hl.color( "%-15s%s" % [node.name, line.chomp], color ) )
            end
          end
          @hl.say(@hl.color "#{node.name} complete", HighLine::MAGENTA)
        end
      end
    end
    threads.each{ |t| t.join }
  end

  def manual_control(cmd='')
    script = <<-EOS.strip_heredoc
        set shortDelay to 0.2
        tell application "Terminal"
          activate
          set newTab to do script -- create a new window with no initial command
          set current settings of newTab to settings set "Grass"
          set frontWindow to window 1
    EOS
    each_with_index do | node, index |
          unless 0 == index
            script << <<-EOS.strip_heredoc
            activate
            tell application "System Events" to keystroke "t" using command down
            delay shortDelay
          EOS
          end
          script << <<-EOS.strip_heredoc
          do script "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -l ubuntu -i #{ssh_key} #{node.address}"  in frontWindow
          do script "export PS1=\\\"[\\\\033]0;#{node.name}\\\\007]\\\\u@\\\\h:\\\\w>\\\"" in frontWindow
          do script "cd ~/documentcloud" in frontWindow
        EOS
          unless cmd.empty?
            script << "do script \"#{cmd}\" in frontWindow\n"
          end
        end
        script << "end tell\n"
        system 'osascript', *script.split(/\n/).map { |line| ['-e', line] }.flatten
  end


end


class Servers
  # we should never operate on these
  BLACKLIST=Regexp.new('^(app|solr|db)')

  def initialize
    @ec2 = AWS::EC2.new
    @instances = []
    @ec2.instances
        .reject { |i| i.status != :running || i.tags["Name"].blank? || i.tags["Name"].match(BLACKLIST) }
        .each{ |instance| add_node(instance) }
  end

  def add_node(instance)
    node = Node.new(instance.tags["Name"], instance.dns_name, instance )
    @instances.push node
    node
  end

  def instances
    nodes = @instances.dup
    if block_given?
      nodes.reject! { |node| ! yield node }
    end
    InstanceCollection.new(nodes.sort_by{ |node| node.name })
  end

  def workers(range=false)
    range = (range..range) if range.is_a?(Fixnum)
    instances { |i| i.name=~/worker/ && ( range ? range.include?(i.number) : true) }
  end

  def launch(count=1, options={})
    prefix = options.delete(:prefix) || "worker"
    options.reverse_merge!({
        :image_id          => DC::CONFIG['preconfigured_ami_id'],
        :count             => count,
        :security_groups   => ['default'],
        :key_name          => 'DocumentCloud 2014-04-12',
        :instance_type     => 'c1.medium',
        :availability_zone => DC::CONFIG['aws_zone']
      })
    new_instances = @ec2.instances.create(options)
    sleep 1 while new_instances.any? {|i| i.status == :pending }
    start = instances { |i| i.prefixed?(prefix) }.count + 1
    new_nodes = []
    new_instances.each_with_index do | instance, index |
      instance.tag('Name', value: "#{prefix}-#{start+index}" )
      new_nodes << add_node(instance)
    end
    sleep 5 until new_nodes.none? { |node| !node.ssh_open? }
    InstanceCollection.new(new_nodes)
  end


end

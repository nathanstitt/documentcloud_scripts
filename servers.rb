require 'nokogiri'
require 'active_support/all'
require 'net/ssh'
require 'socket'
require 'timeout'
require 'aws'
require 'aws/core'
require 'net/scp'

DC_ROOT   = Pathname.new(__FILE__).dirname.join("../documentcloud")
SECRETS   = YAML.load_file("#{DC_ROOT}/secrets/secrets.yml")['development']
SSH_KEY   = DC_ROOT.join('secrets/keys/documentcloud.pem')
DOC_TYPES = %w{pdf doc docx}
FIND_DOCS_CLAUSE = DOC_TYPES.map{ |ext| "-name '*.#{ext}'"}.join(" -o ")

AWS.config({
  :access_key_id     => SECRETS['aws_access_key'],
  :secret_access_key => SECRETS['aws_secret_key']
})


Thread.abort_on_exception = true

# A Worker is a server that runs jobs on behalf of CloudCrowd
class Worker < Struct.new(:name, :address, :ec2)
  def prefixed?(prefix)
    !name.match(/^#{prefix}/).nil?
  end

  def number
    name[/\d+$/,0].to_i
  end

  def reserved?
    false #number > 0 && number <= 4
  end

  def ssh
    Net::SSH.start( address, 'ubuntu', keys: SSH_KEY, paranoid: false) do |ssh|
      yield ssh
    end
  end

  def download(src, dest)
    Net::SCP.download!(address, "ubuntu", src, dest,:ssh=>{ keys: SSH_KEY, paranoid: false } )
  rescue Net::SCP::Error=>e
    p e
  end

end

# Contains the execution status of a Job
class CrowdJob < Struct.new(:node, :pid, :elapsed, :action)

  # Turns the time reported by ps into a Ruby duration
  # "1:55:59" becomes 1 hour, 55 minutes and 59 seconds
  def duration
    @duration ||= calculate_duration
  end

  def calculate_duration
    return 0.seconds if ! elapsed
    parts = elapsed.split(':').map(&:to_i)
    time = case parts.length
           when 3 then parts[0].hours   + parts[1].minutes   + parts[2].seconds
           when 2 then parts[0].minutes + parts[1].seconds
           else parts[0].seconds
           end
    if elapsed=~/(\d+)-/
      time+=$1.to_i.days
    end
    time
  end

  def work_unit
    @work_unit ||= action[/\((\d+)\)/,1]
  end

end

# Contains a subset of available workers
# Runs commands on them and reports on their health
class InstanceCollection
  include Enumerable

  def initialize(nodes)
    @nodes=nodes
    @hl = HighLine.new
  end

  def address_table
    map do |i| sprintf("%-10s %-20s %s",
      i.name,
      i.ec2.private_dns_name.gsub(/.ec2.internal$/,''),
      i.address
    )
    end
  end

  def each
    @nodes.each{ |n| yield n }
  end

  def idle
    nodes = []
    cmd="ps -o pid,etime,cmd --no-headers --ppid `cat tmp/pids/node.pid`|wc -l"
    execute_on_each(cmd) do |line, success, node, ssh|
      nodes.push(node)  if 0 == line.to_i
    end
    InstanceCollection.new(nodes)
  end

  def kill_jobs_older_than(time)
    each_job do |job, ssh|
      if job.duration > time
        ssh.exec "kill `pstree -p #{job.pid}|perl -ne 'print \" $1\" while /\\((\\d+)\\)/g'`"
        sleep 5
        ssh.exec "kill -9 `pstree -p #{job.pid}|perl -ne 'print \" $1\" while /\\((\\d+)\\)/g'`"
        @hl.say( @hl.color "Killing #{job.action} on #{job.node.name}", HighLine::RED)
      end
    end
  end

  def docs_running_longer_than(time, dest_directory)
    results = {}
    log = File.open("#{dest_directory}/#{Time.now.strftime('%Y%m%dT%H%M')}.txt","w")
    puts "Logging to #{log.path}"
    each_job do |job, ssh|
      next unless job.duration > time
      directory = ssh.exec!("find /tmp -type d -name unit_#{job.work_unit}").to_s.chomp
      if directory.empty?
        @hl.say( @hl.color "Failed to find working directory for #{job}", HighLine::RED)
        next
      end
      doc = ssh.exec!("find #{directory} #{FIND_DOCS_CLAUSE}").to_s.chomp
      if doc.empty?
        @hl.say( @hl.color "Failed find to working file for #{job}", HighLine::RED)
        next
      end
      save_path = "#{dest_directory}/#{job.work_unit}-#{File.basename(doc)}"
      job.node.download( doc, save_path )
      results[job.work_unit] = save_path
      status = "%2s %8s %10s %s" % [job.node.number, job.work_unit, job.elapsed, save_path]
      log.write(status + "\n")
      puts status
    end
    select_cmd = "select j.id as job_id, w.id as work_unit_id, j.action, j.options from jobs j join work_units w on w.job_id = j.id and w.id in(#{results.keys.join(',')})"
    puts select_cmd
    results
  end

  def job_status
    jobs = []
    each_job { |job,ssh| jobs<<job}
    jobs.sort_by{ |job| job.duration }.map do | r |
      sprintf("%-10s %-15s %8s %s", r.node.name, r.elapsed, r.pid, r.action)
    end
  end

  def each_job
    cmd="ps -o pid,etime,cmd --no-headers --ppid `cat tmp/pids/node.pid`"
    execute_on_each(cmd) do |line, success, node, ssh|
      match = line.match(/\s*(\d+)\s*(\S+)\s(.*)/)
      if ! match
        @hl.say( @hl.color "#{line} failed to match", HighLine::RED)
        next
      end
      yield CrowdJob.new(node, match[1], match[2], match[3]), ssh
    end
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
    execute_on_each(cmd) do |line, success, node|
      color = ( success ? HighLine::GREEN : HighLine::RED )
      @hl.say(@hl.color( "%-15s%s" % [node.name, line.chomp], color ) )
    end
  end

  def execute_on_each(cmd)
    threads = []
    each do | node |
      threads << Thread.new do
        node.ssh do | ssh |
          prefix =<<-EOS.strip_heredoc
          source /usr/local/share/chruby/chruby.sh
          source /usr/local/share/chruby/auto.sh
          cd ~/documentcloud

          EOS
          ssh.exec!(prefix + cmd) do | channel, stream, data |
            data.each_line do | line |
              yield line, (channel==:stdout), node, ssh
            end
          end
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
          do script "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -l ubuntu -i #{SSH_KEY} #{node.address}"  in frontWindow
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
  BLACKLIST  = Regexp.new('^(app|solr|db)')
  def initialize
    @ec2 = AWS::EC2.new
    @instances = []
    @ec2.instances
    .reject { |i| i.status != :running || i.tags["Name"].blank? || i.tags["Name"].match(BLACKLIST) }
    .each{ |instance| add_worker(instance) }
  end


  def add_worker(instance)
    worker = Worker.new(instance.tags["Name"], instance.dns_name, instance )
    @instances.push worker
    worker
  end

  def instances
    workers = @instances.dup
    if block_given?
      workers.reject! { |worker| ! yield worker }
    end
    InstanceCollection.new(workers.sort_by{ |worker| worker.name })
  end

  def workers(range=false)
    range = (range..range) if range.is_a?(Fixnum)
    instances { |i| i.name=~/worker/ && ( range ? range.include?(i.number) : true) }
  end

  def launch(count=1, options={})
    prefix = options.delete(:prefix) || "worker"
    script = options.delete(:script)
    options.reverse_merge!({
        :image_id          => 'ami-86d404ee',
        :count             => count,
        :security_groups   => ['default'],
        :key_name          => 'DocumentCloud 2014-04-12',
        :instance_type     => 'c3.large',
        :availability_zone => 'us-east-1c'
      })
    new_instances = @ec2.instances.create(options)
    sleep 1 while new_instances.any? {|i| i.status == :pending }
    start = instances.max_by{|i|i.number}.number + 1
    new_workers = []
    new_instances.each_with_index do | instance, index |
      instance.tag('Name', value: sprintf("%s%02d", prefix, start+index) )
      new_workers << add_worker(instance)
    end
    sleep 5 until new_workers.none? { |worker| !ssh_open?(worker) }
    collection = InstanceCollection.new(new_workers)
    if script
      collection.execute(script)
    end
    collection
  end
  def ssh_open?(worker)
    Timeout::timeout(1) do
      begin
        TCPSocket.new(worker.address, 22).close
        true
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        false
      end
    end
  rescue Timeout::Error
    false
  end


end

class Puppet::Provider::ElasticPlugin < Puppet::Provider

  def homedir
    case Facter.value('osfamily')
    when 'OpenBSD'
      '/usr/local/elasticsearch'
    else
      '/usr/share/elasticsearch'
    end
  end

  def exists?
    es_version
    if !File.exists?(pluginfile)
      debug "Plugin file #{pluginfile} does not exist"
      return false
    elsif File.exists?(pluginfile) && readpluginfile != pluginfile_content
      debug "Got #{readpluginfile} Expected #{pluginfile_content}. Removing for reinstall"
      self.destroy
      return false
    else
      debug "Plugin exists"
      return true
    end
  end

  def pluginfile_content
    return @resource[:name] if is1x?

    if @resource[:name].split("/").count == 1 # Official plugin
      version = plugin_version(@resource[:name])
      return "#{@resource[:name]}/#{version}"
    else
      return @resource[:name]
    end
  end

  def pluginfile
    if @resource[:plugin_path]
      File.join(@resource[:plugin_dir], @resource[:plugin_path], '.name')
    else
      File.join(@resource[:plugin_dir], plugin_name(@resource[:name]), '.name')
    end
  end

  def writepluginfile
    File.open(pluginfile, 'w') do |file|
      file.write pluginfile_content
    end
  end

  def readpluginfile
    f = File.open(pluginfile)
    f.readline
  end

  def install1x
    if !@resource[:url].nil?
      commands = [ plugin_name(@resource[:name]), '--url', @resource[:url] ]
    elsif !@resource[:source].nil?
      commands = [ plugin_name(@resource[:name]), '--url', "file://#{@resource[:source]}" ]
    else
      commands = [ @resource[:name] ]
    end
    commands
  end

  def install2x
    if !@resource[:url].nil?
      commands = [ @resource[:url] ]
    elsif !@resource[:source].nil?
      commands = [ "file://#{@resource[:source]}" ]
    else
      commands = [ @resource[:name] ]
    end
    commands
  end

  def proxy_args url
    parsed = URI(url)
    ['http', 'https'].map do |schema|
      [:host, :port, :user, :password].map do |param|
        option = parsed.send(param)
        if not option.nil?
          "-D#{schema}.proxy#{param.to_s.capitalize}=#{option}"
        end
      end
    end.flatten.compact
  end

  def create
    es_version
    commands = []
    commands << 'install'
    commands << '--batch' if is22x?
    commands += install1x if is1x?
    commands += install2x if is2x?
    debug("Commands: #{commands.inspect}")

    retry_count = 3
    retry_times = 0
    begin
      with_environment do
        plugin(commands)
      end
    rescue Puppet::ExecutionFailure => e
      retry_times += 1
      debug("Failed to install plugin. Retrying... #{retry_times} of #{retry_count}")
      sleep 2
      retry if retry_times < retry_count
      raise "Failed to install plugin. Received error: #{e.inspect}"
    end

    writepluginfile
  end

  def destroy
    with_environment do
      plugin(['remove', @resource[:name]])
    end
  end

  def es_version
    return @es_version if @es_version
    es_save = ENV['ES_INCLUDE']
    java_save = ENV['JAVA_HOME']

    os = Facter.value('osfamily')
    if os == 'OpenBSD'
      ENV['JAVA_HOME'] = javapathhelper('-h', 'elasticsearch').chomp
      ENV['ES_INCLUDE'] = '/etc/elasticsearch/elasticsearch.in.sh'
    end
    begin
      version = es('-version')
    rescue
      ENV['ES_INCLUDE'] = es_save if es_save
      ENV['JAVA_HOME'] = java_save if java_save
      raise "Unknown ES version. Got #{version.inspect}"
    ensure
      ENV['ES_INCLUDE'] = es_save if es_save
      ENV['JAVA_HOME'] = java_save if java_save
      @es_version = version.scan(/\d+\.\d+\.\d+(?:\-\S+)?/).first
      debug "Found ES version #{@es_version}"
    end
  end

  def is1x?
    Puppet::Util::Package.versioncmp(@es_version, '2.0.0') < 0
  end

  def is2x?
    (Puppet::Util::Package.versioncmp(@es_version, '2.0.0') >= 0) && (Puppet::Util::Package.versioncmp(@es_version, '3.0.0') < 0)
  end

  def is22x?
    (Puppet::Util::Package.versioncmp(@es_version, '2.2.0') >= 0) && (Puppet::Util::Package.versioncmp(@es_version, '3.0.0') < 0)
  end


  def plugin_version(plugin_name)
    vendor, plugin, version = plugin_name.split('/')
    return @es_version if is2x? && version.nil?
    return version.scan(/\d+\.\d+\.\d+(?:\-\S+)?/).first unless version.nil?
    return false
  end

  def plugin_name(plugin_name)
    vendor, plugin, version = plugin_name.split('/')

    endname = vendor if plugin.nil? # If its a single name plugin like the ES 2.x official plugins
    endname = plugin.gsub(/(elasticsearch-|es-)/, '') unless plugin.nil?

    endname
  end

  # Run a command wrapped in necessary env vars
  def with_environment(&block)
    env_vars = {
      'ES_JAVA_OPTS' => ["-Des.path.conf=#{homedir}"],
    }
    saved_vars = {}

    if @resource[:proxy]
      env_vars['ES_JAVA_OPTS'] += proxy_args(@resource[:proxy])
    end

    env_vars['ES_JAVA_OPTS'] = env_vars['ES_JAVA_OPTS'].join(' ')

    env_vars.each do |env_var, value|
      saved_vars[env_var] = ENV[env_var]
      ENV[env_var] = value
    end

    ret = block.call

    saved_vars.each do |env_var, value|
      ENV[env_var] = value
    end

    return ret
  end

end

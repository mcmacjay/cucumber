require 'logger'
require 'gherkin/tag_expression'

module Cucumber
  class Configuration
    include Constantize
    
    attr_reader :settings
    
    def initialize(out_stream = STDOUT, error_stream = STDERR)
      @error_stream = error_stream
      @overridden_paths = []
      @expanded_args = []
      @settings ||= default_options
      @settings[:out_stream] = out_stream
    end

    def self.add_setting(name, opts={})
      if opts[:alias]
        alias_method name, opts[:alias]
        alias_method "#{name}=", "#{opts[:alias]}="
        alias_method "#{name}?", "#{opts[:alias]}?"
      else
        define_method("#{name}=") {|val| @settings[name] = val}
        define_method(name)       { @settings[name] }
        define_method("#{name}?") { !!(send name) }
      end
    end

    add_setting :out_stream
    add_setting :strict
    add_setting :tag_expressions
    add_setting :tags, :alias => :tag_expressions
    add_setting :wip
    add_setting :verbose
    add_setting :drb
    add_setting :profiles
    add_setting :formats
    add_setting :disable_profile_loading

    def [](key)
      @settings[key]
    end

    def []=(key, value)
      @settings[key] = value
    end
    
    def tag_expression
      Gherkin::TagExpression.new(@settings[:tag_expressions])
    end
    
    def custom_profiles
      @settings[:profiles] - ['default']
    end
    
    def non_stdout_formats
      @settings[:formats].select {|format, output| output != STDOUT }
    end

    def stdout_formats
      @settings[:formats].select {|format, output| output == STDOUT }
    end
        
    def expanded_args_without_drb
      return @expanded_args_without_drb  if @expanded_args_without_drb
      @expanded_args_without_drb = (
        previous_flag_was_profile = false
        @expanded_args.reject do |arg|
          if previous_flag_was_profile
            previous_flag_was_profile = false
            next true
          end
          if [Cli::ArgsParser::PROFILE_SHORT_FLAG, Cli::ArgsParser::PROFILE_LONG_FLAG].include?(arg)
            previous_flag_was_profile = true
            next true
          end
          arg == Cli::ArgsParser::DRB_FLAG || @overridden_paths.include?(arg)
        end
      )

      @expanded_args_without_drb.push("--no-profile") unless @expanded_args_without_drb.include?(Cli::ArgsParser::NO_PROFILE_LONG_FLAG) || @expanded_args_without_drb.include?(Cli::ArgsParser::NO_PROFILE_SHORT_FLAG)
      @expanded_args_without_drb
    end

    def reverse_merge(other_options)
      @settings ||= default_options
      
      other_settings = other_options.settings
      @settings = other_settings.merge(@settings)
      @settings[:require] += other_settings[:require]
      @settings[:excludes] += other_settings[:excludes]
      @settings[:name_regexps] += other_settings[:name_regexps]
      @settings[:tag_expressions] += other_settings[:tag_expressions]
      @settings[:env_vars] = other_settings[:env_vars].merge(@settings[:env_vars])
      
      if @settings[:paths].empty?
        @settings[:paths] = other_settings[:paths]
      else

      @overridden_paths += (other_settings[:paths] - @settings[:paths])

      end
      @settings[:source] &= other_settings[:source]
      @settings[:snippets] &= other_settings[:snippets]
      @settings[:strict] |= other_settings[:strict]

      #@settings[:profiles] += other_settings[:profiles]

      @expanded_args += other_settings[:expanded_args]

      if @settings[:formats].empty?
        @settings[:formats] = other_settings[:formats]
      else
        @settings[:formats] += other_settings[:formats]
        @settings[:formats] = stdout_formats[0..0] + non_stdout_formats
      end
    end
    
    def filters
      @settings.values_at(:name_regexps, :tag_expressions).select{|v| !v.empty?}.first || []
    end

    def drb_port
      @settings[:drb_port].to_i if @settings[:drb_port]
    end

    def formatter_class(format)
      if(builtin = Cli::ArgsParser::BUILTIN_FORMATS[format])
        constantize(builtin[0])
      else
        constantize(format)
      end
    end

    def all_files_to_load
      requires = @settings[:require].empty? ? require_dirs : @settings[:require]
      files = requires.map do |path|
        path = path.gsub(/\\/, '/') # In case we're on windows. Globs don't work with backslashes.
        path = path.gsub(/\/$/, '') # Strip trailing slash.
        File.directory?(path) ? Dir["#{path}/**/*"] : path
      end.flatten.uniq
      remove_excluded_files_from(files)
      files.reject! {|f| !File.file?(f)}
      files.reject! {|f| File.extname(f) == '.feature' }
      files.reject! {|f| f =~ /^http/}
      files.sort
    end

    def step_defs_to_load
      all_files_to_load.reject {|f| f =~ %r{/support/} }
    end

    def support_to_load
      support_files = all_files_to_load.select {|f| f =~ %r{/support/} }
      env_files = support_files.select {|f| f =~ %r{/support/env\..*} }
      other_files = support_files - env_files
      @settings[:dry_run] ? other_files : env_files + other_files
    end

    def feature_files
      potential_feature_files = paths.map do |path|
        path = path.gsub(/\\/, '/') # In case we're on windows. Globs don't work with backslashes.
        path = path.chomp('/')
        if File.directory?(path)
          Dir["#{path}/**/*.feature"]
        elsif path[0..0] == '@' and # @listfile.txt
            File.file?(path[1..-1]) # listfile.txt is a file
          IO.read(path[1..-1]).split
        else
          path
        end
      end.flatten.uniq
      remove_excluded_files_from(potential_feature_files)
      potential_feature_files
    end

    def feature_dirs
      paths.map { |f| File.directory?(f) ? f : File.dirname(f) }.uniq
    end
    
    def log
      logger = Logger.new(@settings[:out_stream])
      logger.formatter = LogFormatter.new
      logger.level = Logger::INFO
      logger.level = Logger::DEBUG if @settings[:verbose]
      logger
    end
    
    class LogFormatter < ::Logger::Formatter
      def call(severity, time, progname, msg)
        msg
      end
    end
    
    def formatters(step_mother)
      # TODO: We should remove the autoformat functionality. That
      # can be done with the gherkin CLI.
      if @settings[:autoformat]
        require 'cucumber/formatter/pretty'
        return [Formatter::Pretty.new(step_mother, nil, self)]
      end

      @settings[:formats].map do |format_and_out|
        format = format_and_out[0]
        path_or_io = format_and_out[1]
        begin
          formatter_class = formatter_class(format)
          formatter_class.new(step_mother, path_or_io, self)
        rescue Exception => e
          e.message << "\nError creating formatter: #{format}"
          raise e
        end
      end
    end
    
    private

    def default_options
      {
        :strict       => false,
        :require      => [],
        :dry_run      => false,
        :formats      => [],
        :excludes     => [],
        :tag_expressions  => [],
        :name_regexps => [],
        :env_vars     => {},
        :diff_enabled => true,
        :profiles => [],
        :disable_profile_loading => false
      }
    end

    def paths
      @settings[:paths].empty? ? ['features'] : @settings[:paths]
    end

    def remove_excluded_files_from(files)
      files.reject! {|path| @settings[:excludes].detect {|pattern| path =~ pattern } }
    end

    def require_dirs
      feature_dirs + Dir['vendor/{gems,plugins}/*/cucumber']
    end
  end
  
  def self.configuration=(configuration)
    @configuration = configuration
  end
  
  def self.configuration
    @configuration ||= Cucumber::Configuration.new
  end

  def self.configure
    yield configuration if block_given?
  end
end

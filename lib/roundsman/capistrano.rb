require 'json'
require 'tempfile'

::Capistrano::Configuration.instance(:must_exist).load do

  namespace :roundsman do

    def run_list(*recipes)
      if recipes.any?
        set :run_list, recipes
        install_ruby if fetch(:run_roundsman_checks, true) && install_ruby?
        run_chef
      else
        Array(fetch(:run_list))
      end
    end

    def set_default(name, *args, &block)
      @_defaults ||= []
      @_overridden_defaults ||= []
      @_defaults << name
      if exists?(name)
        @_overridden_defaults << name
      else
        set(name, *args, &block)
      end
    end

    def roundsman_working_dir(*path)
      ensure_roundsman_working_dir
      File.join(fetch(:roundsman_working_dir), *path)
    end

    def sudo(command, *args)
      run "#{top.sudo} #{command}", *args
    end

    def run(*args)
      if fetch(:stream_roundsman_output)
        top.stream *args
      else
        top.run *args
      end
    end

    set_default :roundsman_working_dir, "/tmp/roundsman"
    set_default :stream_roundsman_output, true
    set_default(:roundsman_user) { fetch(:user) { capture('whoami').strip } }
    set_default :debug_chef, false
    set_default :package_manager, 'apt-get'
    set_default :run_roundsman_checks, true

    desc "Lists configuration"
    task :configuration do
      @_defaults.sort_by {|sym| sym.to_s}.each do |name|
        display_name = ":#{name},".ljust(30)
        if variables[name].is_a?(Proc)
          value = "<block>"
        else
          value = fetch(name).inspect
          value = "#{value[0..40]}... (truncated)" if value.length > 40
        end
        overridden = @_overridden_defaults.include?(name) ? "(overridden)" : ""
        puts "set #{display_name} #{value} #{overridden}"
      end
    end

    desc "Prepares the server for chef"
    task :install_ruby do
      install.default
    end

    desc "Runs chef"
    task :run_chef do
      chef.default
    end

    def ensure_roundsman_working_dir
      run "mkdir -p #{fetch(:roundsman_working_dir)}"
      run "mkdir -p #{fetch(:roundsman_working_dir)}/cache"
      sudo "chown -R #{fetch(:roundsman_user)} #{fetch(:roundsman_working_dir)}"
    end

    def install_ruby?
      installed_version = capture("ruby --version || true").strip
      if installed_version.include?("not found")
        logger.info "No version of Ruby could be found."
        return true
      end
      required_version = fetch(:ruby_version).gsub("-", "")
      if fetch(:care_about_ruby_version)
        if installed_version.include?(required_version)
          logger.info "Ruby #{installed_version} matches the required version: #{required_version}."
          return false
        else
          logger.info "Ruby version mismatch. Installed version: #{installed_version}, required is #{required_version}"
          return true
        end
      else
        logger.info "Already installed Ruby #{installed_version}, not #{required_version}. Set :care_about_ruby_version if you want to fix this."
        return false
      end
    end


    namespace :install do

      set_default :ruby_version, "1.9.3-p194"
      set_default :care_about_ruby_version, true
      set_default :ruby_install_dir, "/usr/local"

      set_default :ruby_dependencies do
        %w(git-core curl build-essential bison openssl
          libreadline6 libreadline6-dev zlib1g zlib1g-dev libssl-dev
          libyaml-dev libxml2-dev libxslt-dev autoconf libc6-dev ncurses-dev
          vim wget tree)
      end

      set_default :ruby_install_script do
        %Q{
          set -e
          cd #{roundsman_working_dir}
          rm -rf ruby-build
          git clone -q https://github.com/sstephenson/ruby-build.git
          cd ruby-build
          ./install.sh
          CONFIGURE_OPTS='--disable-install-rdoc' ruby-build #{fetch(:ruby_version)} #{fetch(:ruby_install_dir)}
        }
      end

      task :default, :except => { :no_chef => true } do
        if install_ruby?
          dependencies
          ruby
        end
      end

      desc "Installs ruby."
      task :ruby, :except => { :no_chef => true } do
        put fetch(:ruby_install_script), roundsman_working_dir("install_ruby.sh"), :via => :scp
        sudo "bash #{roundsman_working_dir("install_ruby.sh")}"
      end

      desc "Installs the dependencies needed for Ruby"
      task :dependencies, :except => { :no_chef => true } do
        ensure_supported_distro
        sudo "#{fetch(:package_manager)} -yq update"
        sudo "#{fetch(:package_manager)} -yq install #{fetch(:ruby_dependencies).join(' ')}"
      end

      desc "Checks if the ruby version installed matches the version specified"
      task :check_ruby_version do
        abort if install_ruby?
      end

      def distribution
        @distribution ||= capture("cat /etc/issue").strip
      end

      def ensure_supported_distro
        logger.info "Using Linux distribution #{distribution}"
        abort "This distribution is not (yet) supported." unless distribution.include?("Ubuntu")
      end

    end

    namespace :chef do

      set_default :chef_version, "~> 11.6.0"
      set_default(:chef_environment) { fetch(:rails_env) }
      set_default :cookbooks_directory, ["config/cookbooks"]
      set_default :databags_directory, "config/data_bags"
      set_default :roles_directory, "config/roles"
      set_default :environments_directory, "config/environments"
      set_default :copyfile_disable, false
      set_default :verbose_logging, true
      set_default :filter_sensitive_settings, [ /password/, /filter_sensitive_settings/ ]

      task :default, :except => { :no_chef => true } do
        ensure_cookbooks_exists
        prepare_chef
        chef_solo
      end

      desc "Generates the config and copies over the cookbooks to the server"
      task :prepare_chef, :except => { :no_chef => true } do
        install if fetch(:run_roundsman_checks, true) && install_chef?
        ensure_cookbooks_exists
        generate_config
        generate_attributes
        copy_cookbooks
      end

      desc "Installs chef"
      task :install, :except => { :no_chef => true } do
        sudo "sh -c 'curl -L https://www.opscode.com/chef/install.sh | bash'"
      end

      desc "Runs the existing chef configuration"
      task :chef_solo, :except => { :no_chef => true } do
        logger.info "Now running chef-solo..."
        sudo "chef-solo -c #{roundsman_working_dir("solo.rb")} -j #{roundsman_working_dir("solo.json")}#{' -l debug' if fetch(:debug_chef)}"
      end

      def ensure_cookbooks_exists
        abort "You must specify at least one recipe when running roundsman.chef" if variables[:run_list].blank?
        abort "No cookbooks found in #{fetch(:cookbooks_directory).inspect}" if cookbooks_paths.empty?
      end

      def cookbooks_paths
        Array(fetch(:cookbooks_directory)).select { |path| File.exist?(path) }
      end

      def cap_path_if_exists(cap_config_name)
        path = fetch(cap_config_name.to_sym)
        File.exists?(path) ? path : nil
      end

      def databags_path
        cap_path_if_exists(:databags_directory)
      end

      def roles_path
        cap_path_if_exists(:roles_directory)
      end

      def environments_path
        cap_path_if_exists(:environments_directory)
      end

      def install_chef?
        required_version = fetch(:chef_version).inspect
        find_servers_for_task(current_task).any? do |server|
          output = capture("which chef-solo || echo 'false'", :hosts => [server]).strip
          output == "false"
        end
      end

      def generate_config
        cookbook_string = cookbooks_paths.map { |c| "File.join(root, #{c.to_s.inspect})" }.join(', ')
        solo_rb = <<-RUBY
          root = File.expand_path(File.dirname(__FILE__))
          file_cache_path File.join(root, "cache")
          cookbook_path [ #{cookbook_string} ]
          role_path File.join(root, #{fetch(:roles_directory).to_s.inspect})
          environment_path File.join(root, #{fetch(:environments_directory).to_s.inspect})
          verbose_logging #{fetch(:verbose_logging)}
          data_bag_path File.join(root, #{fetch(:databags_directory).to_s.inspect})
        RUBY
        if (chef_env = fetch(:chef_environment))
          solo_rb = [solo_rb, "environment #{chef_env.to_s.inspect}"].join("\n")
        end
        put solo_rb, roundsman_working_dir("solo.rb"), :via => :scp
      end

      def generate_attributes
        find_servers_for_task(current_task).each do |server|
          attrs = remove_procs_from_hash(variables.dup, server)
          put attrs.to_json, roundsman_working_dir("solo.json"), :via => :scp, :hosts => [server]
        end
      end

      # Recursively removes procs from hashes. Procs can exist because you specified them like this:
      #
      #     set(:root_password) { Capistrano::CLI.password_prompt("Root password: ") }
      def remove_procs_from_hash(hash, *args)
        new_hash = {}
        hash.each do |key, value|
          next if fetch(:filter_sensitive_settings).find { |regex| regex.match(key.to_s) }
          real_value = if value.respond_to?(:call)
            begin
              if key.to_sym == :run_list
                value.call(*args[0...value.arity])
              else
                value.call
              end
            rescue ::Capistrano::CommandError => e
              logger.debug "Could not get the value of #{key}: #{e.message}"
              nil
            end
          else
            value
          end

          if real_value.is_a?(Hash)
            real_value = remove_procs_from_hash(real_value, *args)
          end
          if real_value != nil && !real_value.class.to_s.include?("Capistrano") # skip capistrano tasks
            new_hash[key] = real_value
          end
        end
        new_hash
      end

      def copy_cookbooks
        tar_file = Tempfile.new("cookbooks.tar")
        begin
          tar_file.close
          env_vars = fetch(:copyfile_disable) && RUBY_PLATFORM.downcase.include?('darwin') ? "COPYFILE_DISABLE=true" : ""
          system "#{env_vars} tar -cjf #{tar_file.path} #{cookbooks_paths.join(' ')} #{databags_path.to_s} #{roles_path.to_s} #{environments_path.to_s}"
          upload tar_file.path, roundsman_working_dir("cookbooks.tar"), :via => :scp
          run "cd #{roundsman_working_dir} && tar -xjf cookbooks.tar"
        ensure
          tar_file.unlink
        end
      end

    end

  end
end

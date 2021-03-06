module Autoproj
    ENV_FILENAME =
        if Autobuild.windows? then "env.bat"
        else "env.sh"
        end

    class Environment < Autobuild::Environment
        attr_reader :root_dir

        def prepare(root_dir)
            @root_dir = root_dir
            set 'AUTOPROJ_CURRENT_ROOT', root_dir
            super()
        end

        def filter_original_env(name, env)
            Autoproj.filter_out_paths_in_workspace(env)
        end

        def export_env_sh(subdir = nil, options = Hash.new)
            if subdir.kind_of?(Hash)
                subdir, options = nil, subdir
            end
            options = validate_options options,
                shell_helpers: true

            filename = if subdir
                   File.join(root_dir, subdir, ENV_FILENAME)
               else
                   File.join(root_dir, ENV_FILENAME)
               end

            shell_dir = File.expand_path(File.join("..", "..", "shell"), File.dirname(__FILE__))
            if options[:shell_helpers]
                source_after(File.join(shell_dir, "autoproj_sh"))
            end

            existing_content =
                begin File.read(filename)
                rescue SystemCallError
                end

            StringIO.open(new_content = String.new, 'w') do |io|
                if inherit?
                    io.write <<-EOF
                    if test -n "$AUTOPROJ_CURRENT_ROOT" && test "$AUTOPROJ_CURRENT_ROOT" != "#{root_dir}"; then
                        echo "the env.sh from $AUTOPROJ_CURRENT_ROOT is already loaded. Start a new shell before sourcing this one"
                        return
                    fi
                    EOF
                end
                super(io)
            end

            if new_content != existing_content
                File.open(filename, 'w') { |io| io.write new_content }
                true
            end
        end
    end

    # @deprecated call Autoproj.env.set instead
    def self.env_set(name, *value)
        env.set(name, *value)
    end
    # @deprecated call Autoproj.env.add instead
    def self.env_add(name, *value)
        env.add(name, *value)
    end
    # @deprecated call Autoproj.env.set_path instead
    def self.env_set_path(name, *value)
        env.set_path(name, *value)
    end
    # @deprecated call Autoproj.env.add_path instead
    def self.env_add_path(name, *value)
        env.add_path(name, *value)
    end
    # @deprecated call Autoproj.env.source_after instead
    def self.env_source_file(file)
        env.source_after(file)
    end
    # @deprecated call Autoproj.env.source_after instead
    def self.env_source_after(file)
        env.source_after(file)
    end
    # @deprecated call Autoproj.env.source_before instead
    def self.env_source_before(file)
        env.source_before(file)
    end
    # @deprecated call Autoproj.env.inherit instead
    def self.env_inherit(*names)
        env.inherit(*names)
    end
    # @deprecated use Autoproj.env.isolate instead
    def self.set_initial_env
        isolate_environment
    end
    # @deprecated use Autoproj.env.isolate instead
    def self.isolate_environment
        env.isolate
    end
    # @deprecated call Autoproj.env.prepare directly
    def self.prepare_environment(env = Autoproj.env, manifest = Autoproj.manifest)
        env.prepare(manifest)
    end
    # @deprecated use Autoproj.env.export_env_sh instead
    def self.export_env_sh(subdir = nil)
        env.export_env_sh(subdir)
    end
end

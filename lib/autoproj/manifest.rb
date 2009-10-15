require 'yaml'
require 'utilrb/kernel/options'
require 'nokogiri'
require 'set'

module Autobuild
    class Package
        def os_packages
            @os_packages || Array.new
        end
        def depends_on_os_package(name)
            @os_packages ||= Array.new
            @os_packages << name
        end
    end
end

module Autoproj
    @build_system_dependencies = Set.new
    def self.add_build_system_dependency(*names)
        @build_system_dependencies |= names.to_set
    end
    class << self
        attr_reader :build_system_dependencies
    end

    def self.expand_environment(value)
        # Perform constant expansion on the defined environment variables,
        # including the option set
        options = Autoproj.option_set
        if Autoproj.manifest
            loop do
                new_value = Autoproj.manifest.single_expansion(value, options)
                if new_value == value
                    break
                else
                    value = new_value
                end
            end
        else
            value
        end
    end

    @env_inherit = Set.new
    def self.env_inherit?(name)
        @env_inherit.include?(name)
    end
    def self.env_inherit(*names)
        @env_inherit |= names
    end

    # Set a new environment variable
    def self.env_set(name, *value)
        Autobuild.environment.delete(name)
        env_add(name, *value)
    end
    def self.env_add(name, *value)
        value = value.map { |v| expand_environment(v) }
        Autobuild.env_add(name, *value)
    end
    def self.env_set_path(name, *value)
        Autobuild.environment.delete(name)
        env_add_path(name, *value)
    end
    def self.env_add_path(name, *value)
        value = value.map { |v| expand_environment(v) }
        Autobuild.env_add_path(name, *value)
    end

    class VCSDefinition
        attr_reader :type
        attr_reader :url
        attr_reader :options

        def initialize(type, url, options)
            @type, @url, @options = type, url, options
            if type != "local" && !Autobuild.respond_to?(type)
                raise ConfigError, "version control #{type} is unknown to autoproj"
            end
        end

        def local?
            @type == 'local'
        end

        def create_autobuild_importer
            url = Autoproj.single_expansion(self.url, 'HOME' => ENV['HOME'])
            if url && url !~ /^(\w+:\/)?\/|^\w+\@/
                url = File.expand_path(url, Autoproj.root_dir)
            end
            Autobuild.send(type, url, options)
        end

        def to_s; "#{type}:#{url}" end
    end

    def self.vcs_definition_to_hash(spec)
        if spec.respond_to?(:to_str)
            vcs, *url = spec.to_str.split ':'
            spec = if url.empty?
                       source_dir = File.expand_path(File.join(Autoproj.config_dir, spec))
                       if !File.directory?(source_dir)
                           raise ConfigError, "'#{spec.inspect}' is neither a remote source specification, nor a local source definition"
                       end

                       Hash[:type => 'local', :url => source_dir]
                   else
                       Hash[:type => vcs.to_str, :url => url.join(":").to_str]
                   end
        end

        spec, vcs_options = Kernel.filter_options spec, :type => nil, :url => nil

        return spec.merge(vcs_options)
    end

    # Autoproj configuration files accept VCS definitions in three forms:
    #  * as a plain string, which is a relative/absolute path
    #  * as a plain string, which is a vcs_type:url string
    #  * as a hash
    #
    # This method normalizes the three forms into a VCSDefinition object
    def self.normalize_vcs_definition(spec)
        spec = vcs_definition_to_hash(spec)
        if !(spec[:type] && spec[:url])
            raise ConfigError, "the source specification #{spec.inspect} misses either the VCS type or an URL"
        end

        spec, vcs_options = Kernel.filter_options spec, :type => nil, :url => nil
        return VCSDefinition.new(spec[:type], spec[:url], vcs_options)
    end

    def self.single_expansion(data, definitions)
        definitions.each do |name, expanded|
            data = data.gsub /\$#{Regexp.quote(name)}\b/, expanded
        end
        data
    end

    # A source is a version control repository which contains general source
    # information with package version control information (source.yml file),
    # package definitions (.autobuild files), and finally definition of
    # dependencies that are provided by the operating system (.osdeps file).
    class Source
        # The VCSDefinition object that defines the version control holding
        # information for this source. Local package sets (i.e. the ones that are not
        # under version control) use the 'local' version control name. For them,
        # local? returns true.
        attr_accessor :vcs
        attr_reader :source_definition
        attr_reader :constants_definitions

        # Create this source from a VCSDefinition object
        def initialize(vcs)
            @vcs = vcs
        end

        # True if this source has already been checked out on the local autoproj
        # installation
        def present?; File.directory?(local_dir) end
        # True if this source is local, i.e. is not under a version control
        def local?; vcs.local? end
        # The directory in which data for this source will be checked out
        def local_dir
            if local?
                vcs.url
            else
                File.join(Autoproj.remotes_dir, automatic_name)
            end
        end

        # A name generated from the VCS url
        def automatic_name
            vcs.to_s.gsub(/[^\w]/, '_')
        end

        # Returns the source name
        def name
            if @source_definition then
                @source_definition['name'] || automatic_name
            elsif @name
                @name
            else
                automatic_name
            end
        end

        def raw_description_file
            if !present?
                raise InternalError, "source #{vcs} has not been fetched yet, cannot load description for it"
            end

            source_file = File.join(local_dir, "source.yml")
            if !File.exists?(source_file)
                raise ConfigError, "source #{vcs.type}:#{vcs.url} should have a source.yml file, but does not"
            end

            begin
                source_definition = YAML.load(File.read(source_file))
            rescue ArgumentError => e
                raise ConfigError, "error in #{source_file}: #{e.message}"
            end

            if !source_definition
                raise ConfigError, "#{source_file} does not have a 'name' field"
            end

            source_definition
        end

        def load_name
            definition = raw_description_file
            @name = definition['name']
        rescue InternalError
        end

        # Load the source.yml file that describes this source, and resolve the
        # $BLABLA values that are in there. Use #raw_description_file to avoid
        # resolving those values
        def load_description_file
            @source_definition = raw_description_file

            # Compute the definition of constants
            begin
                constants = source_definition['constants'] || Hash.new
                constants['HOME'] = ENV['HOME']

                redo_expansion = true
                @constants_definitions = constants 
                while redo_expansion
                    redo_expansion = false
                    constants.dup.each do |name, url|
                        # Extract all expansions in the url
                        if url =~ /\$(\w+)/
                            expansion_name = $1

                            if constants[expansion_name]
                                constants[name] = single_expansion(url)
                            else
                                begin constants[name] = single_expansion(url,
                                                 expansion_name => Autoproj.user_config(expansion_name))
                                rescue ConfigError => e
                                    raise ConfigError, "constant '#{expansion_name}', used in the definition of '#{name}' is defined nowhere"
                                end
                            end
                            redo_expansion = true
                        end
                    end
                end

            rescue ConfigError => e
                raise ConfigError, "#{File.join(local_dir, "source.yml")}: #{e.message}", e.backtrace
            end
        end

        # True if the given string contains expansions
        def contains_expansion?(string); string =~ /\$/ end

        def single_expansion(data, additional_expansions = Hash.new)
            Autoproj.single_expansion(data, additional_expansions.merge(constants_definitions))
        end

        # Expands the given string as much as possible using the expansions
        # listed in the source.yml file, and returns it. Raises if not all
        # variables can be expanded.
        def expand(data, additional_expansions = Hash.new)
            if !source_definition
                load_description_file
            end

            if data.respond_to?(:to_hash)
                data.dup.each do |name, value|
                    data[name] = expand(value, additional_expansions)
                end
            else
                data = single_expansion(data, additional_expansions)
                if contains_expansion?(data)
                    raise ConfigError, "some expansions are not defined in #{data.inspect}"
                end
            end

            data
        end

        # Returns an importer definition for the given package, if one is
        # available. Otherwise returns nil.
        #
        # The returned value is a VCSDefinition object.
        def importer_definition_for(package_name)
            urls = source_definition['urls'] || Hash.new
            urls['HOME'] = ENV['HOME']

            all_vcs     = source_definition['version_control']
            if all_vcs && !all_vcs.kind_of?(Array)
                raise ConfigError, "wrong format for the version_control field"
            end

            vcs_spec = Hash.new

            if all_vcs
                all_vcs.each do |spec|
                    name, spec = spec.to_a.first
                    if Regexp.new(name) =~ package_name
                        vcs_spec = vcs_spec.merge(spec)
                    end
                end
            end

            if !vcs_spec.empty?
                expansions = Hash["PACKAGE" => package_name]

                vcs_spec = expand(vcs_spec, expansions)
                vcs_spec = Autoproj.vcs_definition_to_hash(vcs_spec)
                vcs_spec.dup.each do |name, value|
                    vcs_spec[name] = expand(value, expansions)
                end
                vcs_spec

                Autoproj.normalize_vcs_definition(vcs_spec)
            end
        rescue ConfigError => e
            raise ConfigError, "#{e.message} in the source.yml file of #{name} (#{File.join(local_dir, "source.yml")})", e.backtrace
        end

        def each_package
            if !block_given?
                return enum_for(:each_package)
            end

            Autoproj.manifest.packages.each do |pkg_name, (pkg, source, file)|
                if source.name == name
                    yield(pkg)
                end
            end
        end
    end

    class Manifest
        FakePackage = Struct.new :name, :srcdir
	def self.load(file)
            begin
                data = YAML.load(File.read(file))
            rescue Errno::ENOENT
                raise ConfigError, "expected an autoproj configuration in #{File.expand_path(File.dirname(file))}, but #{file} does not exist"
            rescue ArgumentError => e
                raise ConfigError, "error in #{file}: #{e.message}"
            end
	    Manifest.new(file, data)
	end

        # The manifest data as a Hash
        attr_reader :data

        # The set of packages defined so far as a mapping from package name to 
        # [Autobuild::Package, source, file] tuple
        attr_reader :packages

        # A mapping from package names into PackageManifest objects
        attr_reader :package_manifests

        attr_reader :file

	def initialize(file, data)
            @file = file
	    @data = data
            @packages = Hash.new
            @package_manifests = Hash.new

            if Autoproj.has_config_key?('manifest_source')
                @vcs = Autoproj.normalize_vcs_definition(Autoproj.user_config('manifest_source'))
            end
	end

        # Lists the autobuild files that are in the package sets we know of
	def each_autobuild_file(source_name = nil, &block)
            if !block_given?
                return enum_for(:each_source_file, source_name)
            end

            # This looks very inefficient, but it is because source names are
            # contained in source.yml and we must therefore load that file to
            # check the package set name ...
            #
            # And honestly I don't think someone will have 20 000 package sets
            done_something = false
            each_source do |source| 
                next if source_name && source.name != source_name
                done_something = true

                Dir.glob(File.join(source.local_dir, "*.autobuild")).each do |file|
                    yield(source, file)
                end
            end

            if source_name && !done_something
                raise ConfigError, "source '#{source_name}' does not exist"
            end
	end

        def each_osdeps_file
            if !block_given?
                return enum_for(:each_source_file)
            end

            each_source do |source|
		Dir.glob(File.join(source.local_dir, "*.osdeps")).each do |file|
		    yield(source, file)
		end
            end
        end

        def has_remote_sources?
            each_remote_source(false).any? { true }
        end

        # Like #each_source, but filters out local package sets
        def each_remote_source(load_description = true)
            if !block_given?
                enum_for(:each_remote_source, load_description)
            else
                each_source(load_description) do |source|
                    if !source.local?
                        yield(source)
                    end
                end
            end
        end

        # call-seq:
        #   each_source { |source_description| ... }
        #
        # Lists all package sets defined in this manifest, by yielding a Source
        # object that describes it.
        def each_source(load_description = true)
            if !block_given?
                return enum_for(:each_source, load_description)
            end

            return if !data['package_sets']

	    data['package_sets'].each do |spec|
                # Look up for short notation (i.e. not an explicit hash). It is
                # either vcs_type:url or just url. In the latter case, we expect
                # 'url' to be a path to a local directory
                vcs_def = begin
                              Autoproj.normalize_vcs_definition(spec)
                          rescue ConfigError => e
                              raise ConfigError, "in #{file}: #{e.message}"
                          end

                source = Source.new(vcs_def)
                if source.present? && load_description
                    source.load_description_file
                else
                    # Try to load just the name from the source.yml file
                    source.load_name
                end

                yield(source)
            end
        end

        # Register a new package
        def register_package(package, source, file)
            @packages[package.name] = [package, source, file]
        end

        def definition_source(package_name)
            @packages[package_name][1]
        end
        def definition_file(package_name)
            @packages[package_name][2]
        end

        # Lists all defined packages and where they have been defined
        def each_package
            if !block_given?
                return enum_for(:each_package)
            end
            packages.each_value { |package, _| yield(package) }
        end

        def self.update_remote_source(source)
            importer     = source.vcs.create_autobuild_importer
            fake_package = FakePackage.new(source.automatic_name, source.local_dir)

            importer.import(fake_package)
        rescue Autobuild::ConfigException => e
            raise ConfigError, e.message, e.backtrace
        end

        attr_reader :vcs
        def self.import_whole_installation(vcs, into)
            importer     = vcs.create_autobuild_importer
            fake_package = FakePackage.new('autoproj main configuration', into)
            importer.import(fake_package)
        rescue Autobuild::ConfigException => e
            raise ConfigError, "cannot import autoproj configuration: #{e.message}", e.backtrace
        end

        def update_yourself
            Manifest.import_whole_installation(vcs, Autoproj.config_dir)
        end

        def update_remote_sources
            # Iterate on the remote sources, without loading the source.yml
            # file (we're not ready for that yet)
            each_remote_source(false) do |source|
                Manifest.update_remote_source(source)
            end
        end

        # Sets up the package importers based on the information listed in
        # the source's source.yml 
        #
        # The priority logic is that we take the package sets one by one in the
        # order listed in the autoproj main manifest, and first come first used.
        #
        # A set that defines a particular package in its autobuild file
        # *must* provide the corresponding VCS line in its source.yml file.
        # However, it is possible for a source that does *not* define a package
        # to override the VCS
        #
        # In other words: if package P is defined by source S1, and source S0
        # imports S1, then
        #  * S1 must have a VCS line for P
        #  * S0 can have a VCS line for P, which would override the one defined
        #    by S1
        def load_importers
            packages.each_value do |package, package_source, package_source_file|
                vcs = each_source.find do |source|
                    vcs = source.importer_definition_for(package.name)
                    if vcs
                        break(vcs)
                    elsif package_source.name == source.name
                        break
                    end
                end

                if vcs
                    Autoproj.add_build_system_dependency vcs.type
                    package.importer = vcs.create_autobuild_importer
                else
                    raise ConfigError, "source #{package_source.name} defines #{package.name}, but does not provide a version control definition for it"
                end
            end
        end

        # +name+ can either be the name of a source or the name of a package. In
        # the first case, we return all packages defined by that source. In the
        # latter case, we return the singleton array [name]
        def resolve_package_set(name)
            if Autobuild::Package[name]
                [name]
            else
                source = each_source.find { |source| source.name == name }
                if !source
                    raise ConfigError, "#{name} is neither a package nor a source"
                end
                packages.values.find_all { |pkg, pkg_src, _| pkg_src.name == source.name }.
                    map { |pkg, _| pkg.name }
            end
        end

        # Returns the packages contained in the provided layout definition
        #
        # If recursive is false, yields only the packages at this level.
        # Otherwise, return all packages.
        def layout_packages(layout_def, recursive)
            result = []
            layout_def.each do |value|
                if !value.kind_of?(Hash) # sublayout
                    result.concat(resolve_package_set(value))
                end
            end

            if recursive
                each_sublayout(layout_def) do |sublayout_name, sublayout_def|
                    result.concat(layout_packages(sublayout_def, true))
                end
            end

            result
        end

        def each_sublayout(layout_def)
            layout_def.each do |value|
                if value.kind_of?(Hash)
                    name, layout = value.find { true }
                    yield(name, layout)
                end
            end
        end

        # Looks into the layout setup in the manifest, and yields each layout
        # and sublayout in order
        def each_package_set(selection, layout_name = '/', layout_def = data['layout'], &block)
            if !layout_def
                yield('', default_packages, default_packages)
                return nil
            end

            selection = selection.to_set

            # First of all, do the packages at this level
            packages = layout_packages(layout_def, false)
            if selection && !selection.any? { |sel| layout_name =~ /^\/?#{Regexp.new(sel)}\/?/ }
                selected_packages = packages.find_all { |pkg_name| selection.include?(pkg_name) }
            else
                selected_packages = packages.dup
            end
            if !packages.empty?
                yield(layout_name, packages.to_set, selected_packages.to_set)
            end

            # Now, enumerate the sublayouts
            each_sublayout(layout_def) do |subname, sublayout|
                each_package_set(selection, "#{layout_name}#{subname}/", sublayout, &block)
            end
        end

        def default_packages
            names = if layout = data['layout']
                        layout_packages(layout, true)
                    else
                        # No layout, all packages are selected
                        packages.values.map do |package, source, _|
                            package.name
                        end
                    end
            names.to_set
        end

        # Loads the package's manifest.xml files, and extracts dependency
        # information from them. The dependency information is then used applied
        # to the autobuild packages.
        #
        # Right now, the absence of a manifest makes autoproj only issue a
        # warning. This will later be changed into an error.
        def load_package_manifests(selected_packages)
            packages.each_value do |package, source, file|
                next unless selected_packages.include?(package.name)
                manifest_path = File.join(package.srcdir, "manifest.xml")
                if !File.file?(manifest_path)
                    Autoproj.warn "#{package.name} from #{source.name} does not have a manifest"
                    next
                end

                manifest = PackageManifest.load(package, manifest_path)
                package_manifests[package.name] = manifest

                manifest.each_package_dependency do |name|
                    if Autoproj.verbose
                        STDERR.puts "  #{package.name} depends on #{name}"
                    end
                    begin
                        package.depends_on name
                    rescue Autobuild::ConfigException => e
                        raise ConfigError, "manifest of #{package.name} from #{source.name} lists '#{name}' as dependency, but this package does not exist (manifest file: #{manifest_path})"
                    end
                end
            end
        end

        AUTOPROJ_OSDEPS = File.join(File.expand_path(File.dirname(__FILE__)), 'default.osdeps')
        # Returns an OSDependencies instance that defined the known OS packages,
        # as well as how to install them
        def known_os_packages
            osdeps = OSDependencies.load(AUTOPROJ_OSDEPS)

            each_osdeps_file do |source, file|
                osdeps.merge(OSDependencies.load(file))
            end
            osdeps
        end

        def install_os_dependencies
            osdeps = known_os_packages

            all_packages = Set.new
            package_manifests.each_value do |pkg_manifest|
                all_packages |= pkg_manifest.each_os_dependency.to_set
            end

            osdeps.install(all_packages)
        end
    end

    # The singleton manifest object on which the current run works
    class << self
        attr_accessor :manifest
    end

    class PackageManifest
        def self.load(package, file)
            doc = Nokogiri::XML(File.read(file))
            PackageManifest.new(package, doc)
        end

        # The Autobuild::Package instance this manifest applies on
        attr_reader :package
        # The raw XML data as a Nokogiri document
        attr_reader :xml

        def initialize(package, doc)
            @package = package
            @xml = doc
        end

        def each_os_dependency
            if block_given?
                xml.xpath('//rosdep').each do |node|
                    yield(node['name'])
                end
                package.os_packages.each do |name|
                    yield(name)
                end
            else
                enum_for :each_os_dependency
            end
        end

        def each_package_dependency
            if block_given?
                xml.xpath('//depend').each do |node|
                    dependency = node['package']
                    if dependency
                        yield(dependency)
                    else
                        raise ConfigError, "manifest of #{package.name} has a <depend> tag without a 'package' attribute"
                    end
                end
            else
                enum_for :each_package_dependency
            end
        end
    end
end

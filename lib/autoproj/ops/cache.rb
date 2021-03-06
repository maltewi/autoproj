module Autoproj
    module Ops
        class Cache
            attr_reader :cache_dir
            attr_reader :manifest

            def initialize(cache_dir, manifest)
                @cache_dir = cache_dir
                @manifest  = manifest
            end

            def with_retry(count)
                (count + 1).times do |i|
                    begin
                        break yield
                    rescue Autobuild::SubcommandFailed
                        if i == count
                            raise
                        else
                            Autobuild.message "  failed, retrying (#{i}/#{count})"
                        end
                    end
                end
            end

            def git_cache_dir
                File.join(cache_dir, 'git')
            end

            def cache_git(pkg, options = Hash.new)
                pkg.importdir = File.join(git_cache_dir, pkg.name)
                if options[:checkout_only] && File.directory?(pkg.importdir)
                    return
                end

                pkg.importer.local_branch = nil
                pkg.importer.remote_branch = nil
                pkg.importer.remote_name = 'autobuild'

                if !File.directory?(pkg.importdir)
                    FileUtils.mkdir_p File.dirname(pkg.importdir)
                    Autobuild::Subprocess.run("autoproj-cache", "import", Autobuild.tool(:git), "--git-dir", pkg.importdir, 'init', "--bare")
                end
                pkg.importer.update_remotes_configuration(pkg)

                with_retry(10) do
                    Autobuild::Subprocess.run('autoproj-cache', :import, Autobuild.tool('git'), '--git-dir', pkg.importdir, 'remote', 'update', 'autobuild')
                end
                with_retry(10) do
                    Autobuild::Subprocess.run('autoproj-cache', :import, Autobuild.tool('git'), '--git-dir', pkg.importdir, 'fetch', 'autobuild', '--tags')
                end
                Autobuild::Subprocess.run('autoproj-cache', :import, Autobuild.tool('git'), '--git-dir', pkg.importdir, 'gc', '--prune=all')
            end

            def archive_cache_dir
                File.join(cache_dir, 'archives')
            end

            def cache_archive(pkg)
                pkg.importer.cachedir = archive_cache_dir
                with_retry(10) do
                    pkg.importer.update_cache(pkg)
                end
            end

            def create_or_update(*package_names, all: true, keep_going: false, checkout_only: false)
                FileUtils.mkdir_p cache_dir

                if package_names.empty?
                    packages =
                        if all
                            manifest.each_autobuild_package
                        else
                            manifest.all_selected_source_packages.map(&:autobuild)
                        end
                else
                    packages = package_names.map do |name|
                        if pkg = manifest.find_autobuild_package(name)
                            pkg
                        else
                            raise PackageNotFound, "no package named #{name}"
                        end
                    end
                end

                packages = packages.sort_by(&:name)

                total = packages.size
                Autoproj.message "Handling #{total} packages"
                packages.each_with_index do |pkg, i|
                    next if pkg.srcdir != pkg.importdir # No need to process this one, it is uses another package's import
                    begin
                        case pkg.importer
                        when Autobuild::Git
                            Autoproj.message "  [#{i}/#{total}] caching #{pkg.name} (git)"
                            cache_git(pkg, checkout_only: checkout_only)
                        when Autobuild::ArchiveImporter
                            Autoproj.message "  [#{i}/#{total}] caching #{pkg.name} (archive)"
                            cache_archive(pkg)
                        else
                            Autoproj.message "  [#{i}/#{total}] not caching #{pkg.name} (cannot cache #{pkg.importer.class})"
                        end
                    rescue Interrupt
                        raise
                    rescue ::Exception => e
                        if keep_going
                            pkg.error "       failed to cache #{pkg.name}, but going on as requested"
                            lines = e.to_s.split("\n")
                            if lines.empty?
                                lines = e.message.split("\n")
                            end
                            if lines.empty?
                                lines = ["unknown error"]
                            end
                            pkg.message(lines.shift, :red, :bold)
                            lines.each do |line|
                                pkg.message(line)
                            end
                            nil
                        else
                            raise
                        end
                    end
                end
            end
        end
    end
end


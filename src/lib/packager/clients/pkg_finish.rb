# ------------------------------------------------------------------------------
# Copyright (c) 2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# ------------------------------------------------------------------------------

require "installation/finish_client"
require "y2packager/repository"
require "packager/cfa/zypp_conf"
require "packager/cfa/dnf_conf"

Yast.import "InstURL"

module Yast
  # Finish client for packager
  class PkgFinishClient < ::Installation::FinishClient
    include Yast::I18n
    include Yast::Logger

    # Path to libzypp repositories
    REPOS_DIR = "/etc/zypp/repos.d".freeze
    # Path to failed_packages file
    FAILED_PKGS_PATH = "/var/lib/YaST2/failed_packages".freeze
    # Command to create a tar.gz to back-up old repositories
    TAR_CMD = "/usr/bin/mkdir -p '%<target>s' && cd '%<target>s' "\
              "&& /bin/tar -czf '%<archive>s' '%<source>s'".freeze
    # Format of the timestamp to be used as repositories backup
    BACKUP_TIMESTAMP_FORMAT = "%Y%m%d-%H%M%S".freeze
    # Map the CFAs to package managers
    PKG_MAPPING = {
      "dnf"     => Packager::CFA::DnfConf,
      "libzypp" => Packager::CFA::ZyppConf
    }.freeze

    # Constructor
    def initialize
      super
      textdomain "packager"

      Yast.import "Pkg"
      Yast.import "Installation"
      Yast.import "Mode"
      Yast.import "Stage"
      Yast.import "String"
      Yast.import "FileUtils"
      Yast.import "Packages"
      Yast.import "Directory"
      Yast.import "ProductFeatures"
      Yast.import "InstFunctions"
    end

    # @see Implements ::Installation::FinishClient#modes
    def modes
      [:installation, :update, :autoinst]
    end

    # @see Implements ::Installation::FinishClient#title
    def title
      _("Saving the software manager configuration...")
    end

    # @see Implements ::Installation::FinishClient#write
    def write
      if Stage.cont
        # AutoYaST second stage. We only have to disable local repos.
        Pkg.SourceLoad
        disable_local_repos
        # save all repositories and finish target
        Pkg.SourceSaveAll
        Pkg.TargetFinish
        return nil
      end

      # Remove (backup) all sources not used during the update
      # BNC #556469: Backup and remove all the old repositories before any Pkg::SourceSaveAll call
      backup_all_target_sources if Stage.initial && Mode.update

      # See bnc #384827, #381360
      if Mode.update
        log.info("Adding default repositories")
        WFM.call("inst_extrasources")
      end

      # If repositories weren't load during installation (for example, in openSUSE
      # if online repositories were not enabled), resolvables should be loaded now.
      Pkg.SourceLoad
      remove_auto_added_sources
      # AutoYaST: disable_local_repos will be called in second install
      disable_local_repos unless InstFunctions.second_stage_required?

      # save all repositories and finish target
      Pkg.SourceSaveAll
      remove_duplicates
      Pkg.TargetFinish

      # save repository metadata cache to the installed system
      # (needs to be done _after_ saving repositories, see bnc#700881)
      Pkg.SourceCacheCopyTo(Installation.destdir)

      # Patching /etc/zypp/zypp.conf in order not to install
      # recommended packages, doc-packages,...
      # (needed for products like CASP)
      if ProductFeatures.GetBooleanFeature("software", "minimalistic_libzypp_config")
        set_minimalistic_pkg_conf
      end

      # copy list of failed packages to installed system
      if File.exist?(FAILED_PKGS_PATH)
        ::FileUtils.cp(FAILED_PKGS_PATH, File.join(Installation.destdir, FAILED_PKGS_PATH),
          preserve: true)
      end

      nil
    end

  private

    # Checks if given source repo should be disabled
    #
    # Currently CD / DVD repositories are disabled after installation, when
    # enabled in control file
    #
    # @param source [Symbol] if :cd or :dvd then control file is checked if the
    #                        repo should be disabled
    # @return [Boolean] true if the repo should be disabled
    def disable_media_repo?(source)
      return false if ![:cd, :dvd].include?(source)

      ProductFeatures.GetBooleanFeature("software", "disable_media_repo")
    end

    # Backup old sources
    #
    # During upgrade, old sources are reinitialized
    # either as enabled or disabled.
    # The old sources from target should go away.
    def backup_all_target_sources
      if !File.exist?(REPOS_DIR)
        log.error("Directory #{REPOS_DIR} doesn't exist!")
        return
      end

      current_repos = SCR.Read(path(".target.dir"), REPOS_DIR)

      if current_repos.nil? || current_repos.empty?
        log.warn("There are currently no repos in #{REPOS_DIR} conf dir")
        return
      else
        log.info("These repos currently exist on a target: #{current_repos}")
      end

      # Backup repos.d
      repos_backup_dir = File.join(Directory.vardir, "repos.d_backup")
      backup_old_sources(REPOS_DIR, repos_backup_dir).nil?

      # Clean old repositories
      remove_old_sources(current_repos)

      # Sync sources
      sync_target_sources

      nil
    end

    # Disable given repositories if needed
    #
    # Given a local repository:
    #
    # * if all products it contains are available through another repository,
    #   then it will be disabled;
    # * if some product is not available through another repository, then it
    #   will be left untouched.
    #
    # As a side note, not installed base products will be ignored when taking
    # this decision.
    #
    # @return [Array<Y2Packager::Repository>] List of disabled repositories
    def disable_local_repos
      local_repos, remote_repos = *::Y2Packager::Repository.enabled.partition(&:local?)
      remote_products = remote_repos.map(&:products).flatten.uniq
      non_installed_base = Y2Packager::Product.available_base_products.reject(&:installed?)
      products_whitelist = (remote_products + non_installed_base).uniq

      log.info "Products available in remote repositories: #{remote_products.map(&:name)}"
      log.info "Not installed base products: #{non_installed_base.map(&:name)} "

      local_repos.each_with_object([]) do |repo, disabled|
        if repo.products.empty?
          log.info("Repo #{repo.repo_id} (#{repo.name}) does not have products; ignored")
          next
        end

        uncovered = repo.products.reject { |p| products_whitelist.include?(p) }
        disable = if disable_media_repo?(repo.scheme)
          log.info("Repo #{repo.repo_id} (#{repo.name}) is at CD / DVD; disabling")
          true
        elsif uncovered.empty?
          log.info("Repo #{repo.repo_id} (#{repo.name}) will be disabled because products " \
                   "are present in other repositories")
          true
        else
          log.info("Repo #{repo.repo_id} (#{repo.name}) cannot be disabled because these " \
                   "products are not available through other repos: #{uncovered.map(&:name)}")
          false
        end

        if disable
          repo.disable!
          disabled << repo
        end
      end
    end

    # Remove the temporary repositories created by the installer for its own
    # purposes
    #
    # This includes the add-on repository created from the self-update repo and
    # the fallback repo used in some cases to read the products information
    def remove_auto_added_sources
      log.info("Removing optional self-update addon repositories and fallback repository...")
      repos = ::Y2Packager::Repository.all
      repos.each do |r|
        log.debug("Evaluating repo: #{r}")
        next unless added_by_installer?(r)

        log.info("Removing auto-added repository (self update addon or fallback repo) #{r.name}")
        Pkg.SourceDelete(r.repo_id)
      end
    end

    # Whether the given repository was created for the own purposes of the
    # installer
    #
    # @see #remove_auto_added_sources
    #
    # @param repo [Y2Packager::Repository]
    # @return [Boolean]
    def added_by_installer?(repo)
      # Remove the fallback repository added only to read the list of
      # products (fate#325482)
      return true if repo.url == Yast::InstURL.fallback_repo_url

      # Also remove the repositories with name beginning with the "SelfUpdate" and
      # with the "dir://" scheme
      repo.name.start_with?("SelfUpdate") && repo.scheme == :dir
    end

    # Backup sources
    #
    # @param source [String] Path of sources to backup
    # @param target [String] Directory to store backup
    # @return [String,nil] Name of the backup archive (locate in the given target directory);
    #                      nil if the backup failed
    def backup_old_sources(source, target)
      archive_name = "repos_#{Time.now.strftime(BACKUP_TIMESTAMP_FORMAT)}.tgz"
      compress_cmd = format(TAR_CMD,
        target:  String.Quote(target),
        archive: archive_name,
        source:  String.Quote(source))
      cmd = SCR.Execute(path(".target.bash_output"), compress_cmd)
      if cmd["exit"].zero?
        archive_name
      else
        log.error("Unable to backup current repos; Command >#{compress_cmd}< returned: #{cmd}")
        nil
      end
    end

    # Remove old sources
    #
    # @param repos [Array<String>] List of repositories to remove
    def remove_old_sources(repos)
      repos.each do |repo|
        file = File.join(REPOS_DIR, repo)
        log.info("Removing target repository #{file}")
        log.error("Cannot remove #{repo} file") if !SCR.Execute(path(".target.remove"), file)
      end
      log.info("All old repositories were removed from the target")
    end

    # Reload the target to sync the removed repositories with libzypp
    # repomanager
    def sync_target_sources
      Pkg.TargetFinish
      Pkg.TargetInitialize(Installation.destdir)
    end

    # Set package manager configuration to install the minimal amount of packages
    #
    # @see Yast::Packager::CFA::ZyppConf#set_minimalistic!
    def set_minimalistic_pkg_conf
      PKG_MAPPING.each do |pkg, cfa|
        next unless File.file?(File.join(Installation.destdir, cfa::PATH))

        log.info("Setting #{pkg} configuration as minimalistic")
        config = cfa.new
        config.load
        config.set_minimalistic!
        config.save
      end
    end

    # Remove duplicate repositories. If a repository with the same alias
    # already exists libzypp saves it with suffix ".repo_1".
    # The duplicate repositories comes from an RPM package
    # @see bsc#1194546
    def remove_duplicates
      # all repositories, including the disabled ones
      repos = Pkg.SourceGetCurrent(false)

      to_delete = repos.select do |repo|
        Yast::Pkg.SourceGeneralData(repo)["file"]&.match?(/\.repo_\d+\z/)
      end

      return if to_delete.empty?

      to_delete.each do |repo|
        log.info("Deleting duplicate repository #{Yast::Pkg.SourceGeneralData(repo)["file"]}")
        Pkg.SourceDelete(repo)
      end

      Pkg.SourceSaveAll
    end
  end
end

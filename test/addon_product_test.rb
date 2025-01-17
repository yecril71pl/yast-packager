#! /usr/bin/env rspec

require_relative "./test_helper"
require_relative "product_factory"
require "uri"

Yast.import "AddOnProduct"

describe Yast::AddOnProduct do
  subject { Yast::AddOnProduct }

  describe "#renamed?" do
    let(:other_product) do
      Y2Packager::Resolvable.new(
        ProductFactory.create_product("kind" => :product, "deps" => [])
      )
    end
    let(:products) { [other_product] }

    before do
      subject.main
      allow(Y2Packager::Resolvable).to receive(:find)
        .and_return(products)
    end

    context "when rename is included in the fallback list" do
      it "returns true" do
        expect(Yast::AddOnProduct.renamed?("SUSE_SLES", "SLES")).to eq(true)
      end
    end

    context "when product rename is not known" do
      it "returns false" do
        expect(Yast::AddOnProduct.renamed?("foo", "bar")).to eq(false)
      end
    end

    context "when according to libzypp a product is renamed" do
      before do
        subject.main
        allow(Y2Packager::Repository).to receive(:all).and_return([repo0])
      end

      let(:repo0) do
        instance_double(
          Y2Packager::Repository, repo_id: 0, url: URI("dvd:///?devices=/dev/sr0"),
          product_dir: "/p0"
        )
      end
      let(:deps) do
        [
          { "obsoletes" => "product:old_product1" },
          { "obsoletes" => "product(old_product2)" },
          { "provides" => "product:new_product" },
          { "provides" => "product(old_name)" }
        ]
      end

      let(:new_product) do
        Y2Packager::Resolvable.new(
          ProductFactory.create_product("kind" => :product,
            "name" => "new_product", "version" => "1.0",
            "arch" => "x86_64", "source" => "1",
            "product_package" => "new_product-release",
            "deps" => [])
        )
      end

      let(:new_product_package) do
        Y2Packager::Resolvable.new(
          "kind"    => :package,
          "name"    => "new_product-release",
          "version" => "1.0",
          "arch"    => "x86_64",
          "source"  => "1",
          "deps"    => deps
        )
      end

      let(:installed_product_package) do
        Y2Packager::Resolvable.new(
          "kind"    => :package,
          "name"    => "installed_product-release",
          "version" => "1.0",
          "arch"    => "x86_64",
          "source"  => "1",
          "deps"    => []
        )
      end

      let(:products) { [new_product] }

      it "returns true" do
        allow(Y2Packager::Resolvable).to receive(:find)
          .with(kind: :package, name: new_product.product_package)
          .and_return([installed_product_package, new_product_package])
        expect(subject.renamed?("old_product1", new_product.name)).to eq(true)
        expect(subject.renamed?("old_product2", new_product.name)).to eq(true)
        expect(subject.renamed?("old_name", new_product.name)).to eq(true)
      end

      context "when renames information has been already loaded" do
        before do
          subject.renamed?("old_name", new_product.name)
        end

        it "does not ask libzypp again" do
          expect(Y2Packager::Resolvable).to_not receive(:find)
          subject.renamed?("old_name", new_product.name)
        end

        context "but a new repo has been added" do
          let(:repo1) do
            instance_double(
              Y2Packager::Repository, repo_id: 1, url: URI("dvd:///?devices=/dev/sr0"),
              product_dir: "/p1"
            )
          end

          before do
            allow(Y2Packager::Repository).to receive(:all).and_return([repo0, repo1])
          end

          it "asks libzypp again" do
            expect(Y2Packager::Resolvable).to receive(:find).and_return([])
            subject.renamed?("old_name", new_product.name)
          end
        end

        context "but the repo_id for a given repo has changed" do
          before do
            allow(repo0).to receive(:repo_id).and_return(1)
          end

          it "asks libzypp again" do
            expect(Y2Packager::Resolvable).to receive(:find).and_return([])
            subject.renamed?("old_name", new_product.name)
          end
        end

        context "but the url for a given repo has changed" do
          before do
            allow(repo0).to receive(:url).and_return(URI("dvd:///?devices=/dev/sr2"))
          end

          it "asks libzypp again" do
            expect(Y2Packager::Resolvable).to receive(:find).and_return([])
            subject.renamed?("old_name", new_product.name)
          end
        end

        context "but the product_dir for a given repo has changed" do
          before do
            allow(repo0).to receive(:product_dir).and_return("/another")
          end

          it "asks libzypp again" do
            expect(Y2Packager::Resolvable).to receive(:find).and_return([])
            subject.renamed?("old_name", new_product["name"])
          end
        end
      end
    end
  end

  describe "#add_rename" do
    before do
      # reset the known renames for each test
      subject.main
    end

    it "adds a new product rename" do
      expect(Yast::AddOnProduct.renamed?("FOO", "BAR")).to eq(false)
      Yast::AddOnProduct.add_rename("FOO", "BAR")
      expect(Yast::AddOnProduct.renamed?("FOO", "BAR")).to eq(true)
    end

    it "keeps the existing renames" do
      # add new rename
      Yast::AddOnProduct.add_rename("SUSE_SLES", "SLES_NEW")
      # check the new rename
      expect(Yast::AddOnProduct.renamed?("SUSE_SLES", "SLES_NEW")).to eq(true)
      # check the already known rename
      expect(Yast::AddOnProduct.renamed?("SUSE_SLES", "SLES")).to eq(true)
    end

    it "handles single rename" do
      # not known yet
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES")).to eq(false)
      # add a single rename
      Yast::AddOnProduct.add_rename("SUSE_SLE", "SLES")

      # the rename is known
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES")).to eq(true)
      # the rest is unknown
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES_SAP")).to eq(false)
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES_NEW")).to eq(false)
    end

    # handle correctly double renames (bsc#1048141)
    it "handles double rename" do
      # not known yet
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES")).to eq(false)
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES_SAP")).to eq(false)

      # add several renames
      Yast::AddOnProduct.add_rename("SUSE_SLE", "SLES")
      Yast::AddOnProduct.add_rename("SUSE_SLE", "SLES_SAP")

      # the renames are known
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES")).to eq(true)
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES_SAP")).to eq(true)
      # the rest is unknown
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES_NEW")).to eq(false)
    end

    # handle correctly multiple renames
    it "handles multiple renames" do
      # not known yet
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES")).to eq(false)
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES_SAP")).to eq(false)
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES_NEW")).to eq(false)

      # add several renames
      Yast::AddOnProduct.add_rename("SUSE_SLE", "SLES")
      Yast::AddOnProduct.add_rename("SUSE_SLE", "SLES_SAP")
      Yast::AddOnProduct.add_rename("SUSE_SLE", "SLES_NEW")

      # all renames are known
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES")).to eq(true)
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES_SAP")).to eq(true)
      expect(Yast::AddOnProduct.renamed?("SUSE_SLE", "SLES_NEW")).to eq(true)
    end
  end

  describe "#SetRepoUrlAlias" do
    let(:url_without_alias) { "http://example.com/repos/SLES11SP2" }
    let(:url) { "http://example.com/repos/SLES11SP2?alias=yourSLES" }
    it "returns nil for invalid input" do
      expect(Yast::AddOnProduct.SetRepoUrlAlias(nil, nil, nil)).to eq nil
    end

    it "returns url untouched if alias and name are empty" do
      expect(Yast::AddOnProduct.SetRepoUrlAlias(url, nil, "")).to eq url
    end

    it "returns url untouched if url do not contain alias" do
      expect(Yast::AddOnProduct.SetRepoUrlAlias(url_without_alias, nil, "mySLES")).to eq(
        url_without_alias
      )
    end

    it "overwrites alias with alias param if provided" do
      expect(Yast::AddOnProduct.SetRepoUrlAlias(url, "mySLES", nil)).to eq(
        "http://example.com/repos/SLES11SP2?alias=mySLES"
      )
    end

    it "overwrites alias with name param if alias is not provided" do
      expect(Yast::AddOnProduct.SetRepoUrlAlias(url, nil, "mySLES")).to eq(
        "http://example.com/repos/SLES11SP2?alias=mySLES"
      )
    end
  end

  describe "#RegisterAddOnProduct" do
    let(:repo_id) { 42 }

    context "the add-on requires registration" do
      before do
        allow(Yast::WorkflowManager).to receive(:WorkflowRequiresRegistration)
          .with(repo_id).and_return(true)
      end

      context "the registration client is installed" do
        before do
          expect(Yast::WFM).to receive(:ClientExists).with("inst_scc").and_return(true)
        end

        it "starts the registration client" do
          expect(Yast::WFM).to receive(:CallFunction)
            .with("inst_scc", ["register_media_addon", repo_id])

          Yast::AddOnProduct.RegisterAddOnProduct(repo_id)
        end
      end

      context "the registration client is not installed" do
        before do
          expect(Yast::WFM).to receive(:ClientExists).with("inst_scc").and_return(false)
        end

        it "asks to install yast2-registration and starts registration if installed" do
          expect(Yast::Package).to receive(:Install).with("yast2-registration").and_return(true)
          expect(Yast::WFM).to receive(:CallFunction)
            .with("inst_scc", ["register_media_addon", repo_id])

          Yast::AddOnProduct.RegisterAddOnProduct(repo_id)
        end

        it "asks to install yast2-registration and skips registration if not installed" do
          expect(Yast::Package).to receive(:Install).with("yast2-registration").and_return(false)
          expect(Yast::WFM).to_not receive(:CallFunction)
            .with("inst_scc", ["register_media_addon", repo_id])
          # also error is shown
          expect(Yast::Report).to receive(:Error)

          Yast::AddOnProduct.RegisterAddOnProduct(repo_id)
        end
      end
    end

    context "the add-on does not require registration" do
      before do
        allow(Yast::WorkflowManager).to receive(:WorkflowRequiresRegistration)
          .with(repo_id).and_return(false)
      end

      it "add-on registration is skipped" do
        expect(Yast::WFM).to_not receive(:CallFunction)
          .with("inst_scc", ["register_media_addon", repo_id])

        Yast::AddOnProduct.RegisterAddOnProduct(repo_id)
      end
    end
  end

  describe "#AddPreselectedAddOnProducts" do
    BASE_URL = "cd:/?devices=/dev/disk/by-id/ata-QEMU_DVD-ROM_QM00001".freeze
    ADDON_REPO = {
      "path" => "/foo", "priority" => 50, "url" => "cd:/?alias=Foo"
    }.freeze

    let(:repo) { ADDON_REPO }
    let(:filelist) do
      [{ "file" => "/add_on_products.xml", "type" => "xml" }]
    end

    before do
      subject.SetBaseProductURL(BASE_URL)
      allow(subject).to receive(:ParseXMLBasedAddOnProductsFile).and_return([repo])
      subject.add_on_products = []
    end

    context "when filelist is empty" do
      let(:filelist) { [] }

      it "just returns true" do
        expect(subject).to_not receive(:GetBaseProductURL)
        subject.AddPreselectedAddOnProducts(filelist)
      end
    end

    context "when filelist is nil" do
      let(:filelist) { nil }

      it "just returns true" do
        expect(subject).to_not receive(:GetBaseProductURL)
        subject.AddPreselectedAddOnProducts(filelist)
      end
    end

    context "when filelist contains XML files" do
      it "parses the XML file" do
        expect(subject).to receive(:ParseXMLBasedAddOnProductsFile).and_return([])
        subject.AddPreselectedAddOnProducts(filelist)
      end
    end

    context "when filelist contains plain-text files" do
      let(:filelist) do
        [{ "file" => "/add_on_products.xml", "type" => "plain" }]
      end

      it "parses the plain file" do
        expect(subject).to receive(:ParsePlainAddOnProductsFile).and_return([])
        subject.AddPreselectedAddOnProducts(filelist)
      end
    end

    context "when filelist contains unsupported file types" do
      let(:filelist) do
        [{ "file" => "/add_on_products.xml", "type" => "unsupported" }]
      end

      it "logs the error" do
        expect(subject.log).to receive(:error).with(/Unsupported/)
        subject.AddPreselectedAddOnProducts(filelist)
      end
    end

    context "when -confirm_license- is not set in add-on description" do
      let(:repo_id) { 1 }
      before do
        allow(Yast::Pkg).to receive(:SourceProductData).with(repo_id)
        allow(subject).to receive(:InstallProductsFromRepository)
        allow(subject).to receive(:ReIntegrateFromScratch)
        allow(subject).to receive(:AddRepo).and_return(repo_id)
        allow(subject).to receive(:add_product_from_cd).and_return(repo_id)
        allow(subject).to receive(:Integrate)
      end

      it "does not check license in AY mode" do
        expect(Yast::Mode).to receive(:auto).and_return(true)
        expect(subject).to_not receive(:AcceptedLicenseAndInfoFile)
        subject.AddPreselectedAddOnProducts(filelist)
      end
      it "checks license in none AY mode" do
        expect(Yast::Mode).to receive(:auto).and_return(false)
        expect(subject).to receive(:AcceptedLicenseAndInfoFile).and_return(true)
        subject.AddPreselectedAddOnProducts(filelist)
      end
    end

    context "when -confirm_license- is defined in add-on description" do
      let(:repo_id) { 1 }
      before do
        allow(Yast::Pkg).to receive(:SourceProductData).with(repo_id)
        allow(subject).to receive(:InstallProductsFromRepository)
        allow(subject).to receive(:ReIntegrateFromScratch)
        allow(subject).to receive(:AddRepo).and_return(repo_id)
        allow(subject).to receive(:add_product_from_cd).and_return(repo_id)
        allow(subject).to receive(:Integrate)
      end

      context "when it is set to true" do
        let(:repo) { ADDON_REPO.merge("confirm_license" => true) }

        it "checks license in AY mode" do
          expect(Yast::Mode).to receive(:auto).and_return(true)
          expect(subject).to receive(:AcceptedLicenseAndInfoFile).and_return(true)
          subject.AddPreselectedAddOnProducts(filelist)
        end
        it "checks license in none AY mode" do
          expect(Yast::Mode).to receive(:auto).and_return(false)
          expect(subject).to receive(:AcceptedLicenseAndInfoFile).and_return(true)
          subject.AddPreselectedAddOnProducts(filelist)
        end
      end

      context "when it is set to false" do
        let(:repo) { ADDON_REPO.merge("confirm_license" => false) }

        it "does not check license in AY mode" do
          expect(Yast::Mode).to receive(:auto).and_return(true)
          expect(subject).to_not receive(:AcceptedLicenseAndInfoFile)
          subject.AddPreselectedAddOnProducts(filelist)
        end
        it "does not check license in none AY mode" do
          expect(Yast::Mode).to receive(:auto).and_return(false)
          expect(subject).to_not receive(:AcceptedLicenseAndInfoFile)
          subject.AddPreselectedAddOnProducts(filelist)
        end
      end
    end

    context "when install_products is given in the add-on description" do
      let(:repo_id) { 1 }
      let(:repo) do
        ADDON_REPO.merge("install_products" => ["available_product",
                                                "not_available_product"])
      end

      before do
        allow(subject).to receive(:AcceptedLicenseAndInfoFile).and_return(true)
        allow(Yast::Pkg).to receive(:SourceProductData).with(repo_id)
        allow(Yast::Pkg).to receive(:ResolvableInstall).with("available_product",
          :product).and_return(true)
        allow(Yast::Pkg).to receive(:ResolvableInstall).with("not_available_product",
          :product).and_return(false)
        allow(subject).to receive(:ReIntegrateFromScratch)
        allow(subject).to receive(:Integrate)
        allow(subject).to receive(:AddRepo).with(repo["url"], repo["path"], repo["priority"])
          .and_return(repo_id)
        allow(Yast::Report).to receive(:Error)
      end

      it "adds the repository" do
        subject.AddPreselectedAddOnProducts(filelist)
        expect(subject.add_on_products).to_not be_empty
      end

      it "tries to install given products" do
        expect(Yast::Pkg).to receive(:ResolvableInstall).with("available_product",
          :product).and_return(true)
        expect(Yast::Pkg).to receive(:ResolvableInstall).with("not_available_product",
          :product).and_return(false)
        subject.AddPreselectedAddOnProducts(filelist)
        expect(subject.selected_installation_products).to eq(["available_product"])
      end

      it "reports an error for none existing products" do
        expect(Yast::Report).to receive(:Error)
          .with(format(_("Product %s not found on media."), "not_available_product"))
        subject.AddPreselectedAddOnProducts(filelist)
      end

    end

    context "when the add-on is on a CD/DVD" do
      let(:repo_id) { 1 }
      let(:cd_url) { "cd:///?device=/dev/sr0" }

      before do
        allow(subject).to receive(:AcceptedLicenseAndInfoFile).and_return(true)
        allow(Yast::Pkg).to receive(:SourceProductData).with(repo_id)
        allow(subject).to receive(:InstallProductsFromRepository)
        allow(subject).to receive(:ReIntegrateFromScratch)
        allow(subject).to receive(:Integrate)
      end

      context "and no product name was given" do
        let(:repo) { ADDON_REPO }

        it "adds the repository" do
          expect(subject).to receive(:AddRepo).with(repo["url"], repo["path"], repo["priority"])
            .and_return(repo_id)
          subject.AddPreselectedAddOnProducts(filelist)
          expect(subject.add_on_products).to_not be_empty
        end

        it "asks for the CD/DVD if the repo could not be added" do
          allow(subject).to receive(:AddRepo).with(repo["url"], repo["path"], repo["priority"])
            .and_return(nil)
          expect(subject).to receive(:AskForCD).and_return(cd_url)
          expect(subject).to receive(:AddRepo).with(cd_url, repo["path"], repo["priority"])
            .and_return(repo_id)
          subject.AddPreselectedAddOnProducts(filelist)
          expect(subject.add_on_products).to_not be_empty
        end

        it "does not add the repository if user cancels the dialog" do
          allow(subject).to receive(:AddRepo).with(repo["url"], repo["path"], repo["priority"])
            .and_return(nil)
          allow(subject).to receive(:AskForCD).and_return(nil)

          subject.AddPreselectedAddOnProducts(filelist)
          expect(subject.add_on_products).to be_empty
        end
      end

      context "and a network scheme is used" do
        let(:repo) { ADDON_REPO.merge("url" => "http://example.net/repo") }

        it "checks whether the network is working" do
          allow(subject).to receive(:AddRepo).and_return(nil)
          expect(Yast::WFM).to receive(:CallFunction).with("inst_network_check", [])
          subject.AddPreselectedAddOnProducts(filelist)
        end
      end

      context "and a product name was given" do
        let(:repo) { ADDON_REPO.merge("name" => "Foo") }
        let(:matching_product) { { "label" => repo["name"] } }
        let(:other_product) { { "label" => "other" } }
        let(:other_repo_id) { 2 }
        let(:other_cd_url) { "cd:///?device=/dev/sr1" }

        context "and the product is found in the CD/DVD" do
          before do
            allow(Yast::Pkg).to receive(:SourceProductData).with(repo_id)
              .and_return(matching_product)
          end

          it "adds the product without asking" do
            expect(subject).to_not receive(:AskForCD)
            expect(subject).to receive(:AddRepo).with(repo["url"], anything, anything)
              .and_return(repo_id)
            subject.AddPreselectedAddOnProducts(filelist)
          end
        end

        context "and the product is not found in the CD/DVD" do
          before do
            allow(Yast::Pkg).to receive(:SourceProductData).with(repo_id)
              .and_return(matching_product)
            allow(Yast::Pkg).to receive(:SourceProductData).with(other_repo_id)
              .and_return(other_product)
          end

          it "does not add the repository if the user cancels the dialog" do
            allow(subject).to receive(:AddRepo).with(repo["url"], anything, anything)
              .and_return(other_repo_id)
            allow(subject).to receive(:AskForCD).and_return(nil)

            expect(Yast::Pkg).to receive(:SourceDelete).with(other_repo_id)
            expect(subject).to_not receive(:Integrate).with(other_repo_id)
            subject.AddPreselectedAddOnProducts(filelist)
            expect(subject.add_on_products).to be_empty
          end

          it "adds the product if the user points to a valid CD/DVD" do
            allow(subject).to receive(:AddRepo).with(repo["url"], repo["path"], repo["priority"])
              .and_return(other_repo_id)
            allow(subject).to receive(:AskForCD).and_return(cd_url)
            allow(subject).to receive(:AddRepo).with(cd_url, repo["path"], repo["priority"])
              .and_return(repo_id)

            expect(Yast::Pkg).to receive(:SourceDelete).with(other_repo_id)
            expect(Yast::Pkg).to_not receive(:SourceDelete).with(repo_id)
            expect(subject).to receive(:Integrate).with(repo_id)
            subject.AddPreselectedAddOnProducts(filelist)
            expect(subject.add_on_products).to_not be_empty
          end

          it "does not break the URL when retrying" do
            allow(subject).to receive(:AddRepo).with(repo["url"], repo["path"], repo["priority"])
              .and_return(nil)
            allow(subject).to receive(:AddRepo).with(other_cd_url, repo["path"], repo["priority"])
              .and_return(other_repo_id)
            allow(subject).to receive(:AddRepo).with(cd_url, repo["path"], repo["priority"])
              .and_return(repo_id)

            # AskForCD receives always
            expect(subject).to receive(:AskForCD).with(repo["url"], repo["name"])
              .and_return(other_cd_url, nil)

            expect(Yast::Pkg).to receive(:SourceDelete).with(other_repo_id)
            expect(subject).to_not receive(:Integrate).with(other_repo_id)
            subject.AddPreselectedAddOnProducts(filelist)
            expect(subject.add_on_products).to be_empty
          end

          context "and check_name option is disabled" do
            let(:repo) { ADDON_REPO.merge("check_name" => true) }
            it "adds the repository" do
              allow(subject).to receive(:AddRepo).with(repo["url"], repo["path"], repo["priority"])
                .and_return(other_repo_id)

              subject.AddPreselectedAddOnProducts(filelist)
              expect(subject.add_on_products).to_not be_empty
            end
          end
        end
      end

      it "removes the product is the license is not accepted" do
        allow(subject).to receive(:AddRepo).with(repo["url"], repo["path"], repo["priority"])
          .and_return(repo_id)
        expect(subject).to receive(:AcceptedLicenseAndInfoFile).and_return(false)
        expect(Yast::Pkg).to receive(:SourceDelete).with(repo_id)
        subject.AddPreselectedAddOnProducts(filelist)
        expect(subject.add_on_products).to be_empty
      end
    end
  end

  describe "#AddRepo" do
    let(:url) { "ftp://user:mypass@example.net/add-on" }
    let(:pth) { "/" }
    let(:prio) { 50 }

    context "when the repo is added successfully" do
      let(:repo_id) { 1 }

      before do
        allow(Yast::Pkg).to receive(:SourceSaveAll)
        allow(Yast::Pkg).to receive(:SourceRefreshNow)
        allow(Yast::Pkg).to receive(:SourceLoad)
      end

      it "returns the new repository id" do
        expect(Yast::Pkg).to receive(:RepositoryAdd)
          .with("enabled" => true, "base_urls" => [url], "prod_dir" => pth, "priority" => prio)
          .and_return(repo_id)
        expect(subject.AddRepo(url, pth, prio)).to eq(repo_id)
      end

      it "sets priority if it is greater than -1" do
        expect(Yast::Pkg).to receive(:RepositoryAdd)
          .with("enabled" => true, "base_urls" => [url], "prod_dir" => pth)
          .and_return(repo_id)
        expect(subject.AddRepo(url, pth, -2)).to eq(repo_id)
      end

      it "refresh packages metadata" do
        allow(Yast::Pkg).to receive(:RepositoryAdd).and_return(repo_id)
        expect(Yast::Pkg).to receive(:SourceSaveAll)
        expect(Yast::Pkg).to receive(:SourceRefreshNow).with(repo_id)
        expect(Yast::Pkg).to receive(:SourceLoad)
        subject.AddRepo(url, pth, prio)
      end
    end

    context "when the repo is not added successfully" do
      it "reports the error and returns nil" do
        allow(Yast::Pkg).to receive(:RepositoryAdd).and_return(nil)
        expect(Yast::Report).to receive(:Error)
          .with(format(_("Unable to add product %s."), "ftp://user:PASSWORD@example.net/add-on"))
        subject.AddRepo(url, pth, prio)
      end
    end
  end

  describe "#Integrate" do
    let(:src_id) { 3 }

    before do
      allow(subject).to receive(:GetCachedFileFromSource)
      allow(Yast::WorkflowManager).to receive(:GetCachedWorkflowFilename)
      allow(Yast::WorkflowManager).to receive(:AddWorkflow)
    end

    context "installer extension package contains y2update.tgz" do
      it "updates the inst-sys with the y2update.tgz" do
        expect(File).to receive(:exist?).with(/\/y2update\.tgz\z/).and_return(true)
        expect(subject).to receive(:UpdateInstSys).with(/\/y2update\.tgz\z/)
        subject.Integrate(src_id)
      end
    end

    context "installer extension package does not contain y2update.tgz" do
      it "does not update inst-sys" do
        expect(File).to receive(:exist?).with(/\/y2update\.tgz\z/).and_return(false)
        expect(subject).to_not receive(:UpdateInstSys)
        subject.Integrate(src_id)
      end
    end
  end

  describe "#IntegrateY2Update" do
    let(:src_id) { 3 }

    before do
      allow(Yast::WorkflowManager).to receive(:GetCachedWorkflowFilename)
      allow(subject).to receive(:GetCachedFileFromSource)
      allow(subject).to receive(:RereadAllSCRAgents)
    end

    context "installer extension package contains y2update.tgz" do
      it "updates the inst-sys with the y2update.tgz" do
        expect(File).to receive(:exist?).with(/\/y2update\.tgz\z/).and_return(true)
        expect(Yast::SCR).to receive(:Execute).and_return("exit" => 0)
        subject.IntegrateY2Update(src_id)
      end
    end

    context "installer extension package does not contain y2update.tgz" do
      it "does not update inst-sys" do
        expect(File).to receive(:exist?).with(/\/y2update\.tgz\z/).and_return(false)
        expect(Yast::SCR).to_not receive(:Execute)
        subject.IntegrateY2Update(src_id)
      end
    end
  end

  describe "#Export" do
    context "autoyast_product is defined" do
      it "sets -product- value to -autoyast_product- value" do
        subject.add_on_products = [{
          "media" => 0, "product_dir" => "/Module-Basesystem", "product" => "sle-module-basesystem",
          "autoyast_product" => "base", "media_url" => "cd:/?devices=/dev/cdrom/"
        }]
        expect(subject.Export).to eq("add_on_products" => [{
          "product_dir" => "/Module-Basesystem", "product" => "base",
          "media_url" => "cd:/?devices=/dev/cdrom/"
        }])
      end
    end

    context "autoyast_product is not defined" do
      it "only removes -autoyast_product- and -media- entry" do
        subject.add_on_products = [{
          "media" => 0, "product_dir" => "/Module-Basesystem", "product" => "sle-module-basesystem",
          "autoyast_product" => nil, "media_url" => "cd:/?devices=/dev/cdrom/"
        }]
        expect(subject.Export).to eq("add_on_products" => [{
          "product_dir" => "/Module-Basesystem",
          "product"     => "sle-module-basesystem",
          "media_url"   => "cd:/?devices=/dev/cdrom/"
        }])
      end
    end
  end

  describe "#ParseXMLBasedAddOnProductsFile" do
    context "Passed xml is not valid" do
      before do
        allow(Yast::FileUtils).to receive(:Exists).and_return(true)

        allow(Yast::XML).to receive(:XMLToYCPFile).and_raise(Yast::XMLDeserializationError)
        allow(Yast::Report).to receive(:Error)
      end

      it "return empty array" do
        expect(subject.ParseXMLBasedAddOnProductsFile("test", "test")).to eq []
      end

      it "shows error report" do
        expect(Yast::Report).to receive(:Error)

        subject.ParseXMLBasedAddOnProductsFile("test", "test")
      end
    end
  end
end

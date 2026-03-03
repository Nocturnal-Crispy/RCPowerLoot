ADDON   := RCPowerLoot
VERSION := $(shell grep '## Version' $(ADDON).toc | sed 's/.*: //')
OUTDIR  := dist
ZIPNAME := $(ADDON)-$(VERSION).zip

WOW_ADDONS := $(HOME)/.steam/steam/steamapps/compatdata/2832488321/pfx/drive_c/Program Files (x86)/World of Warcraft/_retail_/Interface/AddOns

.PHONY: release zip deploy clean

release:
	@OLD=$$(grep '## Version' $(ADDON).toc | sed 's/.*: //'); \
	PATCH=$$(echo $$OLD | cut -d. -f3); \
	NEW_PATCH=$$((PATCH + 1)); \
	NEW=$$(echo $$OLD | sed "s/\.[0-9]*$$/\.$$NEW_PATCH/"); \
	sed -i "s/## Version: .*/## Version: $$NEW/" $(ADDON).toc; \
	echo "Bumped version $$OLD → $$NEW"
	@echo "Tagging v$(VERSION) and pushing to GitHub..."
	@git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	@git push origin "v$(VERSION)"
	@echo "GitHub Actions will build the release ZIP and attach it to the tag."

zip:
	$(eval VERSION := $(shell grep '## Version' $(ADDON).toc | sed 's/.*: //'))
	$(eval ZIPNAME := $(ADDON)-$(VERSION).zip)
	@rm -rf $(OUTDIR)
	@echo "Building $(ZIPNAME)..."
	@mkdir -p $(OUTDIR)/$(ADDON)
	@cp *.lua *.toc $(OUTDIR)/$(ADDON)/
	@cd $(OUTDIR) && zip -r $(ZIPNAME) $(ADDON)/
	@rm -rf $(OUTDIR)/$(ADDON)
	@echo "Created $(OUTDIR)/$(ZIPNAME)"

deploy:
	@echo "Deploying to WoW AddOns..."
	@DEST="$(WOW_ADDONS)/$(ADDON)"; \
	mkdir -p "$$DEST"; \
	cp *.lua *.toc "$$DEST/"; \
	echo "Deployed to $$DEST"

clean:
	@rm -rf $(OUTDIR)

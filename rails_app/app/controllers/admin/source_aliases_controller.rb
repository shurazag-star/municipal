module Admin
  class SourceAliasesController < ApplicationController
    before_action :require_admin!

    def index
      @settings = current_organization.settings || {}
      @aliases = @settings.fetch("source_aliases", {})
    end

    def create
      settings = current_organization.settings || {}
      aliases = settings.fetch("source_aliases", {})
      aliases[params[:alias_text]] = params[:source_type]
      settings["source_aliases"] = aliases
      current_organization.update!(settings: settings)
      redirect_to admin_source_aliases_path
    end
  end
end


module Admin
  class LlmRunsController < ApplicationController
    before_action :require_admin!

    def index
      @llm_runs = LlmRun.order(created_at: :desc).limit(200)
    end
  end
end


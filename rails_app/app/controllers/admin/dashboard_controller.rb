module Admin
  class DashboardController < ApplicationController
    before_action :require_admin!

    def index
      @audit_logs = AuditLog.order(created_at: :desc).limit(50)
      @llm_runs = LlmRun.order(created_at: :desc).limit(20)
    end
  end
end


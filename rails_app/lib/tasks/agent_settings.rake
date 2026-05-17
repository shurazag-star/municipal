namespace :agent_settings do
  desc "Reset old default agent prompts to the current autonomous default"
  task reset_default_prompt: :environment do
    old_marker = "Перед применением изменений всегда показывай пользователю проект изменений"
    updated = AgentSetting.where("system_prompt ILIKE ?", "%#{old_marker}%").update_all(
      system_prompt: AgentSetting::DEFAULT_SYSTEM_PROMPT,
      updated_at: Time.current
    )
    puts "Updated agent settings: #{updated}"
  end
end

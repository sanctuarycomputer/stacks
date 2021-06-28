namespace :stacks do
  desc "Remind people to record hours"
  task :remind_people_to_record_hours => :environment do
    Stacks::Automator.remind_people_to_record_hours
  end
end

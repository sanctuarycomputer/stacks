class CreateLearningTables < ActiveRecord::Migration[6.1]
  def change
    create_table :qualifications do |t|
      t.string :name, null: false
      t.text :description
      t.string :kind, null: false, default: "qualification"
      t.timestamps
      t.index :name, unique: true
    end

    create_table :courses do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :learner_title, null: false
      t.text :description
      t.integer :grace_period_days, null: false, default: 14
      t.boolean :auto_assign, null: false, default: false
      t.references :qualification, foreign_key: true
      t.timestamps
      t.index :name, unique: true
      t.index :slug, unique: true
    end

    create_table :learning_modules do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :summary
      t.string :notion_url
      t.integer :quiz_pass_percent, null: false, default: 80
      t.references :qualification, foreign_key: true
      t.timestamps
      t.index :slug, unique: true
    end

    create_table :course_modules do |t|
      t.references :course, null: false, foreign_key: true
      t.references :learning_module, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index [:course_id, :learning_module_id], unique: true
    end

    create_table :module_steps do |t|
      t.references :learning_module, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.string :kind, null: false
      t.string :title, null: false
      t.string :notion_url
      t.string :auto_check_key
      t.timestamps
    end

    create_table :quiz_questions do |t|
      t.references :learning_module, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.text :prompt, null: false
      t.jsonb :choices, null: false, default: []
      t.integer :correct_index, null: false
      t.text :explanation
      t.timestamps
    end

    create_table :course_assignments do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :course, null: false, foreign_key: true
      t.date :assigned_on, null: false
      t.date :due_on, null: false
      t.references :assigned_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.datetime :completed_at
      t.datetime :waived_at
      t.references :waived_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.text :waive_note
      t.timestamps
      t.index [:admin_user_id, :course_id], unique: true
    end

    create_table :step_completions do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :module_step, null: false, foreign_key: true
      t.datetime :completed_at, null: false
      t.references :completed_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.string :source, null: false
      t.timestamps
      t.index [:admin_user_id, :module_step_id], unique: true
    end

    create_table :quiz_attempts do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :learning_module, null: false, foreign_key: true
      t.jsonb :answers, null: false, default: {}
      t.integer :correct_count, null: false
      t.integer :question_count, null: false
      t.boolean :passed, null: false, default: false
      t.timestamps
    end

    create_table :quiz_retry_grants do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :learning_module, null: false, foreign_key: true
      t.references :granted_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.text :note
      t.timestamps
    end

    create_table :module_completions do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :learning_module, null: false, foreign_key: true
      t.datetime :completed_at, null: false
      t.timestamps
      t.index [:admin_user_id, :learning_module_id], unique: true, name: "index_module_completions_on_user_and_module"
    end

    create_table :qualification_grants do |t|
      t.references :admin_user, null: false, foreign_key: { on_delete: :cascade }
      t.references :qualification, null: false, foreign_key: true
      t.datetime :granted_at, null: false
      t.references :granted_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }
      t.text :note
      t.timestamps
      t.index [:admin_user_id, :qualification_id], unique: true, name: "index_qualification_grants_on_user_and_qualification"
    end
  end
end

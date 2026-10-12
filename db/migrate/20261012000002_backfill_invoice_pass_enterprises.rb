class BackfillInvoicePassEnterprises < ActiveRecord::Migration[6.1]
  # `down` is a one-shot rollback. It removes only passes tagged
  # data["created_by_backfill"], so a legitimate MSO-era garden3d pass is never
  # destroyed, and it refuses to proceed if such a pass has acquired a Trueup
  # (invoice_passes has an FK from trueups and no dependent: option).
  def up
    # MUST come before the loop: the old unique index on start_of_month alone
    # would reject the second pass for a month.
    if index_name_exists?(:invoice_passes, "index_invoice_passes_on_start_of_month")
      remove_index :invoice_passes, name: "index_invoice_passes_on_start_of_month"
    end

    sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    enterprise_by_qbo_account = QboAccount.pluck(:id, :enterprise_id).to_h

    InvoicePass.where(enterprise_id: nil).find_each do |pass|
      counts = pass.invoice_trackers.group(:qbo_account_id).count

      if counts.empty?
        pass.update_columns(enterprise_id: sanctuary.id)
        next
      end

      modal_qbo_account_id = counts.max_by { |_qa, n| n }.first
      pass.update_columns(enterprise_id: enterprise_by_qbo_account.fetch(modal_qbo_account_id))

      # Every OTHER qbo_account on this pass belongs to a different issuer.
      # Generalised over qbo_account_id -- never hardcoded to garden3d or to the
      # seven known mixed months, because production may have gained passes or
      # Index Space / USB Club trackers since this was written.
      counts.keys.reject { |qa_id| qa_id == modal_qbo_account_id }.each do |qa_id|
        other_enterprise_id = enterprise_by_qbo_account.fetch(qa_id)

        other_pass = InvoicePass.find_or_create_by!(
          start_of_month: pass.start_of_month,
          enterprise_id: other_enterprise_id,
        ) { |p| p.data = { "created_by_backfill" => true } }

        pass.invoice_trackers
            .where(qbo_account_id: qa_id)
            .update_all(invoice_pass_id: other_pass.id)
      end
    end

    orphans = InvoicePass.where(enterprise_id: nil).count
    raise "#{orphans} invoice_passes still have no enterprise_id" if orphans.positive?

    change_column_null :invoice_passes, :enterprise_id, false unless column_not_null?(:enterprise_id)
    change_column_null :invoice_passes, :start_of_month, false unless column_not_null?(:start_of_month)

    unless index_name_exists?(:invoice_passes, "index_invoice_passes_on_enterprise_and_month")
      add_index :invoice_passes, [:enterprise_id, :start_of_month],
                unique: true, name: "index_invoice_passes_on_enterprise_and_month"
    end
  end

  def down
    created = InvoicePass.where("data->>'created_by_backfill' = 'true'")

    created.each do |pass|
      if Trueup.where(invoice_pass_id: pass.id).exists?
        raise "InvoicePass #{pass.id} has trueups; refusing to roll back"
      end

      target = InvoicePass.find_by(
        start_of_month: pass.start_of_month,
        enterprise_id: Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME).id,
      )
      raise "No Sanctuary pass for #{pass.start_of_month} to re-merge into" if target.nil?

      pass.invoice_trackers.update_all(invoice_pass_id: target.id)
      pass.destroy!
    end

    if index_name_exists?(:invoice_passes, "index_invoice_passes_on_enterprise_and_month")
      remove_index :invoice_passes, name: "index_invoice_passes_on_enterprise_and_month"
    end

    change_column_null :invoice_passes, :start_of_month, true
    change_column_null :invoice_passes, :enterprise_id, true

    unless index_name_exists?(:invoice_passes, "index_invoice_passes_on_start_of_month")
      add_index :invoice_passes, :start_of_month,
                unique: true, name: "index_invoice_passes_on_start_of_month"
    end
  end

  private

  def column_not_null?(name)
    connection.schema_cache.clear!
    column = connection.columns(:invoice_passes).find { |c| c.name == name.to_s }
    column.present? && !column.null
  end
end

class CreateEmailLogs < ActiveRecord::Migration[5.2]
  def change
    create_table :email_logs do |t|
      t.string :to
      t.string :from
      t.string :subject
      t.text :body
      t.datetime :sent_at

      t.timestamps
    end
  end
end

defmodule IRCBot.Repo.Migrations.AddKarma do
  use Ecto.Migration

  def change do
  	create table(:karma) do
  		add :what, :string
  		add :score, :integer

  		timestamps()
  	end

  	create unique_index(:karma, [:what])
  end
end

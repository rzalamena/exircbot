defmodule IRCBot.Karma do
	use Ecto.Schema
	import Ecto.Changeset
	import Ecto.Query
	alias IRCBot.Karma
	alias IRCBot.Repo

	schema "karma" do
		field :what, :string
		field :score, :integer, default: 0

		timestamps()
	end

	def changeset(karma, params \\ %{}) do
		karma
		|> cast(params, [:what, :score])
		|> validate_required([:what, :score])
		|> validate_length(:what, min: 1)
		|> unique_constraint(:what)
	end

	def karma_get(what) do
		q = from k in Karma,
			where: k.what == ^what,
			select: k
		Repo.one(q)
	end

	def karma_add(what) do
		karma = karma_get(what)
		if karma do
			karma
			|> changeset(%{score: karma.score + 1})
			|> Repo.update
		else
			%Karma{}
			|> changeset(%{what: what, score: 1})
			|> Repo.insert
		end
	end

	def karma_rem(what) do
		karma = karma_get(what)
		if karma do
			karma
			|> changeset(%{score: karma.score - 1})
			|> Repo.update
		else
			%Karma{}
			|> changeset(%{what: what, score: -1})
			|> Repo.insert
		end
	end
end

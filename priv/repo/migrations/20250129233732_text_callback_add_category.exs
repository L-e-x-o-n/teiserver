defmodule Teiserver.Repo.Migrations.TextCallbackAddCategory do
  use Ecto.Migration

  def change do
    alter table(:communication_text_callbacks) do
      add :category, :string, default: ""
    end
  end
end

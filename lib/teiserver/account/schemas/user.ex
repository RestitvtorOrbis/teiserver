defmodule Teiserver.Account.User do
  @moduledoc false
  use TeiserverWeb, :schema
  @behaviour Bodyguard.Policy

  alias Argon2

  # TODO: this is where a user should be defined. This is only a placeholder for now
  @type t :: term()

  schema "account_users" do
    field :name, :string
    field :email, :string
    field :password, :string

    field :icon, :string
    field :colour, :string

    field :data, :map, default: %{}

    field :roles, {:array, :string}, default: []
    field :permissions, {:array, :string}, default: []

    field :restrictions, {:array, :string}, default: []
    field :restricted_until, :utc_datetime

    field :shadowbanned, :boolean, default: false

    # Start time of their last match
    field :last_login, :utc_datetime
    field :last_login_timex, :utc_datetime
    field :last_played, :utc_datetime
    field :last_logout, :utc_datetime

    field :discord_id, :integer
    field :discord_dm_channel_id, :integer
    field :steam_id, :integer

    has_many :user_configs, Teiserver.Config.UserConfig

    # Extra user.ex relations go here
    belongs_to :clan, Teiserver.Clans.Clan
    belongs_to :smurf_of, Teiserver.Account.User

    has_one :user_stat, Teiserver.Account.UserStat

    timestamps()
  end

  def default_data() do
    %{
      rank: 0,
      country: "??",
      moderator: false,
      bot: false,
      verified: false,
      email_change_code: nil,
      last_login: nil,
      last_login_mins: nil,
      last_login_timex: nil,
      restrictions: [],
      restricted_until: nil,
      shadowbanned: false,
      lobby_hash: [],
      hw_hash: nil,
      chobby_hash: nil,
      roles: [],
      print_client_messages: false,
      print_server_messages: false,
      discord_id: nil,
      discord_dm_channel: nil,
      discord_dm_channel_id: nil,
      steam_id: nil
    }
  end

  @doc false
  def changeset(user, attrs \\ %{}) do
    attrs =
      attrs
      |> remove_whitespace([:email])
      |> uniq_lists(~w(permissions roles)a)

    user
    |> cast(
      attrs,
      ~w(name email password icon colour data roles permissions restrictions restricted_until shadowbanned last_login_timex last_login last_played last_logout discord_id discord_dm_channel_id steam_id smurf_of_id clan_id)a
    )
    |> validate_required([:name, :email, :password, :permissions])
    |> unique_constraint(:email)
    |> put_md5_password_hash()
  end

  def changeset(user, attrs, :script) do
    attrs =
      attrs
      |> remove_whitespace([:email])
      |> uniq_lists(~w(permissions roles)a)

    user
    |> cast(
      attrs,
      ~w(name email password icon colour data roles permissions restrictions restricted_until shadowbanned last_login_timex last_login last_played last_logout discord_id discord_dm_channel_id steam_id smurf_of_id clan_id)a
    )
    |> validate_required([:name, :email, :password, :permissions])
    |> unique_constraint(:email)
    |> validate_change(:email, fn :email, email ->
      case Teiserver.CacheUser.valid_email?(email) do
        :ok -> []
        {:error, reason} -> [{:email, reason}]
      end
    end)
    |> put_md5_password_hash()
  end

  def changeset(struct, params, nil), do: changeset(struct, params)

  def changeset(struct, permissions, :permissions) do
    cast(struct, %{permissions: permissions}, [:permissions])
  end

  def changeset(user, attrs, :server_limited_update_user) do
    attrs =
      attrs
      |> remove_whitespace([:email])

    user
    |> cast(
      attrs,
      ~w(name email icon colour clan_id data roles permissions)a
    )
    |> validate_required(~w(name email)a)
    |> unique_constraint(:email)
  end

  def changeset(user, attrs, :limited_with_data) do
    attrs =
      attrs
      |> remove_whitespace([:email])

    user
    |> cast(attrs, ~w(name email icon colour data clan_id)a)
    |> validate_required([:name, :email])
    |> unique_constraint(:email)
  end

  # Updating email or name from user update form requires plain text password confirmation
  def changeset(user, attrs, :user_form) do
    attrs =
      attrs
      |> remove_whitespace([:email])

    cond do
      attrs["password"] == nil or attrs["password"] == "" ->
        user
        |> cast(attrs, [:name, :email])
        |> validate_required([:name, :email])
        |> add_error(
          :password_confirmation,
          "Please enter your password to change your account details."
        )

      Teiserver.Account.verify_plain_password(attrs["password"], user.password) == false ->
        user
        |> cast(attrs, [:name, :email])
        |> validate_required([:name, :email])
        |> add_error(:password_confirmation, "Incorrect password")

      true ->
        user
        |> cast(attrs, [:name, :email])
        |> validate_required([:name, :email])
        |> unique_constraint(:email)
        |> validate_change(:email, fn :email, email ->
          case Teiserver.CacheUser.valid_email?(email) do
            :ok -> []
            {:error, reason} -> [{:email, reason}]
          end
        end)
    end
  end

  # Updating password from password change form
  # New password is in plain text
  # Requires existing password confirmation
  def changeset(user, attrs, :password) do
    cond do
      attrs["existing"] == nil or attrs["existing"] == "" ->
        user
        |> change_plain_password(attrs)
        |> add_error(
          :password_confirmation,
          "Please enter your existing password to change your password."
        )

      Teiserver.Account.verify_plain_password(attrs["existing"], user.password) == false ->
        user
        |> change_plain_password(attrs)
        |> add_error(:existing, "Incorrect password")

      true ->
        user
        |> change_plain_password(attrs)
    end
  end

  # Updating password from password reset form doesn't require existing password
  def changeset(user, attrs, :password_reset) do
    user
    |> cast(attrs, [:password])
    |> validate_password()
    |> validate_confirmation(:password, message: "Passwords do not match")
    |> put_plain_password_hash()
  end

  def changeset(user, attrs, :register, password_type) do
    attrs = remove_whitespace(attrs, [:email])

    data = default_data() |> Map.new(fn {k, v} -> {to_string(k), v} end)

    attrs =
      Map.merge(
        %{
          "icon" => "fa-solid fa-" <> Teiserver.Helper.StylingHelper.random_icon(),
          "colour" => Teiserver.Helper.StylingHelper.random_colour()
        },
        attrs
      )
      |> Map.put("data", data)

    user
    |> cast(attrs, [:name, :email, :password, :icon, :colour, :data])
    |> unique_constraint(:email)
    |> validate_required([:name, :email, :password])
    |> validate_confirmation(:password, required: true, message: "Passwords do not match")
    |> validate_change(:name, fn :name, name ->
      case Teiserver.Account.valid_name?(name, false) do
        :ok -> []
        {:error, reason} -> [{:name, reason}]
      end
    end)
    |> validate_password()
    |> validate_change(:email, fn :email, email ->
      case Teiserver.CacheUser.valid_email?(email) do
        :ok -> []
        {:error, reason} -> [{:email, reason}]
      end
    end)
    |> then(fn changeset ->
      case password_type do
        :plain_password -> put_plain_password_hash(changeset)
        :md5_password -> put_md5_password_hash(changeset)
      end
    end)
  end

  defp change_plain_password(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_password()
    |> validate_confirmation(:password, message: "Does not match password")
    |> put_plain_password_hash()
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 6)
    |> validate_exclusion(:password, ["1B2M2Y8AsgTpgAmY7PhCfg=="],
      message: "password not allowed (legacy empty chobby pass)"
    )
  end

  defp put_plain_password_hash(
         %Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset
       ) do
    change(changeset,
      password:
        Teiserver.Account.spring_md5_password(password) |> Teiserver.Account.hash_password()
    )
  end

  defp put_plain_password_hash(changeset), do: changeset

  defp put_md5_password_hash(
         %Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset
       ) do
    change(changeset, password: Teiserver.Account.hash_password(password))
  end

  defp put_md5_password_hash(changeset), do: changeset

  @spec authorize(any, Plug.Conn.t(), atom) :: boolean
  def authorize(_, conn, _), do: allow?(conn, "admin.user")
  # def authorize(_, _, _), do: false
end

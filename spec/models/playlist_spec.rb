require "rails_helper"

RSpec.describe Playlist do
  let(:user) { create(:user) }

  it "requires a name" do
    expect(build(:playlist, user: user, name: "  ")).not_to be_valid
  end

  it "squishes and trims the name" do
    playlist = create(:playlist, user: user, name: "  Friday   night  ")

    expect(playlist.name).to eq("Friday night")
  end

  it "treats names case-insensitively per user" do
    create(:playlist, user: user, name: "Favourites")

    expect(build(:playlist, user: user, name: "favourites")).not_to be_valid
  end

  it "allows the same name on another account" do
    create(:playlist, user: user, name: "Favourites")

    expect(build(:playlist, user: create(:user), name: "Favourites")).to be_valid
  end

  it "destroys its items when deleted" do
    playlist = create(:playlist, user: user)
    create(:playlist_item, playlist: playlist)

    expect { playlist.destroy }.to change(PlaylistItem, :count).by(-1)
  end
end

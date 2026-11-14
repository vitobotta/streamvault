require "rails_helper"

RSpec.describe PlaylistItem do
  let(:playlist) { create(:playlist) }

  it "appends items in creation order" do
    first = create(:playlist_item, playlist: playlist, title: "First")
    second = create(:playlist_item, playlist: playlist, title: "Second")

    expect(playlist.playlist_items.ordered.to_a).to eq([ first, second ])
    expect(second.position).to be > first.position
  end

  it "rejects the same title twice in one playlist" do
    create(:playlist_item, playlist: playlist, imdb_id: "tt1375666", content_type: :movie)

    duplicate = build(:playlist_item, playlist: playlist, imdb_id: "tt1375666", content_type: :movie)

    expect(duplicate).not_to be_valid
  end

  it "allows the same IMDb ID as a show and a movie" do
    create(:playlist_item, playlist: playlist, imdb_id: "tt1375666", content_type: :movie)

    expect(build(:playlist_item, playlist: playlist, imdb_id: "tt1375666", content_type: :show)).to be_valid
  end

  it "moves an item up and down" do
    first = create(:playlist_item, playlist: playlist, title: "First")
    second = create(:playlist_item, playlist: playlist, title: "Second")

    expect(second.move!("up")).to be true
    expect(playlist.playlist_items.reload.ordered.to_a).to eq([ second, first ])

    expect(second.move!("down")).to be true
    expect(playlist.playlist_items.reload.ordered.to_a).to eq([ first, second ])
  end

  it "does not move past either end" do
    first = create(:playlist_item, playlist: playlist)
    last = create(:playlist_item, playlist: playlist)

    expect(first.move!("up")).to be false
    expect(last.move!("down")).to be false
  end
end

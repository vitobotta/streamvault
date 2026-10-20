require "rails_helper"

RSpec.describe Playback::EpisodeLabel do
  describe ".build" do
    it "joins the show, the position, and the episode name" do
      expect(
        described_class.build(show_title: "Breaking Bad", season: 1, episode: 2, episode_title: "Cat's in the Bag...")
      ).to eq("Breaking Bad · S01E02 · Cat's in the Bag...")
    end

    it "keeps the position when the episode has no name" do
      expect(described_class.build(show_title: "Breaking Bad", season: 2, episode: 11))
        .to eq("Breaking Bad · S02E11")
    end

    it "drops a synthetic placeholder name" do
      [ "Episode 4", "Ep 4", "EPISODE 04", "Episode TBA" ].each do |placeholder|
        expect(described_class.build(show_title: "Severance", season: 1, episode: 4, episode_title: placeholder))
          .to eq("Severance · S01E04"), "expected #{placeholder.inspect} to be treated as a placeholder"
      end
    end

    it "drops a bare episode number used as a name" do
      expect(described_class.build(show_title: "Severance", season: 1, episode: 4, episode_title: "4"))
        .to eq("Severance · S01E04")
    end

    it "keeps a real name that merely starts with 'Episode'" do
      expect(described_class.build(show_title: "Severance", season: 1, episode: 4, episode_title: "Episode 4: The You You Are"))
        .to eq("Severance · S01E04 · Episode 4: The You You Are")
    end

    it "renders the position alone when the show title is unknown" do
      expect(described_class.build(show_title: nil, season: 1, episode: 2, episode_title: "Pilot"))
        .to eq("S01E02 · Pilot")
    end

    it "returns nil rather than a misleading label when nothing is known" do
      expect(described_class.build).to be_nil
      expect(described_class.build(show_title: "  ", episode_title: "Episode 1")).to be_nil
    end

    it "pads and accepts string inputs, including specials" do
      expect(described_class.build(show_title: "Show", season: "0", episode: "7")).to eq("Show · S00E07")
      expect(described_class.position("12", "34")).to eq("S12E34")
    end
  end
end

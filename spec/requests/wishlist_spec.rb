require 'rails_helper'

RSpec.describe "Wishlist", type: :request do
  let(:user) { create(:user) }

  it "requires authentication" do
    get wishlist_index_path

    expect(response).to redirect_to(new_user_session_path)
  end

  it "shows only the current user's wishlist entries" do
    visible = create(:collection_entry, :wishlist, user: user, title: "VISIBLE_WISHLIST_TITLE")
    create(:collection_entry, user: user, title: "HIDDEN_LIBRARY_TITLE")
    create(:collection_entry, :wishlist, user: create(:user), title: "OTHER_USER_TITLE")
    sign_in user

    get wishlist_index_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(visible.title)
    expect(response.body).not_to include("HIDDEN_LIBRARY_TITLE", "OTHER_USER_TITLE")
  end

  it "paginates the scoped wishlist" do
    26.times { |index| create(:collection_entry, :wishlist, user: user, title: "Wish #{index}") }
    sign_in user

    get wishlist_index_path, params: { page: 2, per_page: 25 }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Showing 26")
  end
end

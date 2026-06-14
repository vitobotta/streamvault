require 'rails_helper'

RSpec.describe "Home", type: :request do
  let(:user) { create(:user) }

  describe "GET /" do
    context "when not authenticated" do
      it "redirects to login" do
        get root_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        get root_path
        expect(response).to have_http_status(:ok)
      end
    end
  end
end

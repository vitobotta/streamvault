require 'rails_helper'

RSpec.describe "Registrations", type: :request do
  let(:valid_signup_params) do
    {
      user: {
        email: "newuser@example.com",
        password: "password123",
        password_confirmation: "password123"
      }
    }
  end

  after do
    ENV.delete("ENABLE_SIGNUPS")
  end

  describe "when signups are disabled (default)" do
    before { ENV.delete("ENABLE_SIGNUPS") }

    it "GET /users/sign_up redirects to login with alert" do
      get new_user_registration_path
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to include("New signups are disabled.")
    end

    it "POST /users redirects to login and creates no user" do
      expect {
        post user_registration_path, params: valid_signup_params
      }.not_to change(User, :count)
      expect(response).to redirect_to(new_user_session_path)
    end

    it "does not show the 'Create an account' link on the login page" do
      get new_user_session_path
      expect(response.body).not_to include("Create an account")
    end
  end

  describe "when signups are enabled" do
    before { ENV["ENABLE_SIGNUPS"] = "true" }

    it "GET /users/sign_up renders the signup form" do
      get new_user_registration_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Create account")
    end

    it "POST /users creates a user and redirects" do
      expect {
        post user_registration_path, params: valid_signup_params
      }.to change(User, :count).by(1)
      expect(response).to redirect_to(root_path)
    end

    it "shows the 'Create an account' link on the login page" do
      get new_user_session_path
      expect(response.body).to include("Create an account")
    end
  end

  describe "authenticated user" do
    let(:user) { create(:user) }

    before { sign_in user }

    it "is redirected away from sign_up by Devise regardless of ENABLE_SIGNUPS" do
      ENV.delete("ENABLE_SIGNUPS")
      get new_user_registration_path
      expect(response).to redirect_to(root_path)
    end
  end
end

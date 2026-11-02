require "test_helper"

class InviteCodesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
  end
  test "super admin can generate invite codes" do
    sign_in users(:sure_support_staff)

    assert_difference("InviteCode.count") do
      post invite_codes_url, params: {}
    end
  end

  test "non-super-admin cannot generate invite codes" do
    sign_in users(:family_admin)

    assert_no_difference("InviteCode.count") do
      post invite_codes_url, params: {}
    end

    assert_redirected_to root_path
  end

  test "deleting an invite code asks through the destructive themed confirm" do
    sign_in users(:sure_support_staff)
    InviteCode.generate!

    get invite_codes_url

    assert_response :success
    confirm = JSON.parse(css_select("form[action^='/invite_codes/'] button").first["data-turbo-confirm"])
    assert_equal "outline-destructive", confirm["variant"]
    assert confirm["confirmText"].present?
  end
end

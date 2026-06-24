require "test_helper"

# Night mode: the layout must ship the pre-paint theme script and the
# Light/Auto/Dark segmented toggle wired to the theme Stimulus controller.
class ThemeTest < ActionDispatch::IntegrationTest
  test "layout renders the pre-paint theme script and the toggle" do
    get root_path
    assert_response :success

    # FOUC guard: resolve the stored preference and set data-theme before paint.
    assert_match "myjira-theme", response.body
    assert_match 'setAttribute("data-theme"', response.body

    # Segmented control: three preferences, wired to the theme controller.
    assert_select "div[data-controller=?]", "theme" do
      assert_select "button[data-theme-value=?]", "light"
      assert_select "button[data-theme-value=?]", "auto"
      assert_select "button[data-theme-value=?]", "dark"
    end
  end
end

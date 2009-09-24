require File.dirname(__FILE__) << '/test_helper'

class TempdirTest < Test::Unit::TestCase

  context "Creating a temporary directory" do
  
    setup do
      change_tmpdir_for_testing
    end
    
    should "use a 'rtex' name prefix" do
      RTeX::Tempdir.open do |tempdir|
        assert_equal 'rtex-', File.basename(tempdir.path)[0,5]
      end
    end
    
    should "remove the directory after use if no exception occurs by default" do
      tempdir = nil
      RTeX::Tempdir.open do |tempdir|
        assert File.exists?(tempdir.path) # Check the temp dir exists
      end
      assert !File.exists?(tempdir.path) # Check the temp dir has been removed
    end
    
    should "return the result of the last statement if automatically removing the directory" do
      result = RTeX::Tempdir.open do
        :last
      end
      assert_equal result, :last
    end
    
    should "not remove the directory after use if an exception occurs" do
      tempdir = nil
      assert_raises RuntimeError do
        RTeX::Tempdir.open do |tempdir|
          assert File.directory?(tempdir.path)
          raise "Test exception!"
        end
      end
      assert File.directory?(tempdir.path)
    end
  
  end
  
end

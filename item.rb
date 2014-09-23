# a class to abstract implementation details of rally items

class Item
  def initialize(single_name, state_name, closed_status)
    @singular = single_name
    @state = state_name
    @closed = closed_status
  end

  def name
    @singular
  end

  attr_reader :singular, :state, :closed
end

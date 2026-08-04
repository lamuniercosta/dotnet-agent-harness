Feature: Discount threshold

  The acceptance-level telling of the same boundary DiscountTests pins at the
  unit level: at 100 the discount applies, just below it the total is unchanged.

Scenario: A total at the threshold is discounted
    Given a shopping total of 100
    When the discount is applied
    Then the charged total should be 90

Scenario: A total just below the threshold is unchanged
    Given a shopping total of 99.99
    When the discount is applied
    Then the charged total should be 99.99

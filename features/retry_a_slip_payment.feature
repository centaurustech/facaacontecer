# TODO this should be a temporary approach for the users to retry their payments

Feature: retry a slip payment

  Scenario: when the payment exists
    Given 1 payment
    When I go to "this payment retry page"
    Then I should see "this payment retry link" element
    When I click in "this payment retry link"
    Then I should not be in "this payment page"
    And I should be in "the new payment page"

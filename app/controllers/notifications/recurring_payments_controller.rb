class Notifications::RecurringPaymentsController < ApplicationController

  # Located @ app/controllers/notifications/concerns/payment_status.rb
  include Notifications::PaymentStatus

  # Located @ app/controllers/notifications/concerns/recurring_payment_status.rb
  include Notifications::RecurringPaymentStatus

  respond_to :json

  # Find a payment or else, create one no matter what
  # (doing this due to retrocompatibility)
  before_actions do
    actions(:create) do
      if params["event"].match(/subscription/)
        update_subscription_state params["resource"]["code"], params["resource"]["status"], params["event"]
      elsif params["event"].match(/invoice/)
        create_or_update_invoice(params["resource"], params["date"])
      elsif _params.has_key?(:id)
        @payment = Payment.find_by(code: _params[:id])
        build_payment if @payment.nil?
      else
        render_nothing_with_status(401)
      end
    end
  end

  private

  # Building a payment when a subscription is found
  def build_payment
    @subscription = Subscription.find_by(code: _params[:code])
    if @subscription.present?

      # Create a payment with the params from moip webhook
      @payment = @subscription.payments.create!(url: nil)

      # Update @payment because the CODE attribute is automatically generate on Create
      @payment.update_attributes!(code: _params[:id])
    else
      raise "Subscription couldn't be found!"
    end
  end

  def update_subscription_state code, status, event
    subscription = Subscription.find_by_code(code)
    if event == "subscription.created" || event == "subscription.updated"
      subscription.update_attributes state: status.downcase
    elsif event == "subscription.suspended"
      subscription.update_attributes state: "suspended"
    elsif event == "subscription.activated"
      subscription.update_attributes state: "active"
    elsif event == "subscription.canceled"
      subscription.update_attributes state: "canceled"
    end
  end

  def create_or_update_invoice resource, date
    if invoice = Invoice.find_by(uid: resource["id"])
      invoice.update_attributes! status: Invoice::STATUS[resource["status"]["code"].to_s], created_on_moip_at: date
    else
      Invoice.create!(
        uid: resource["id"],
        subscription_id: Subscription.find_by(code: resource["subscription_code"]).id,
        value: resource["amount"].to_f/100,
        occurrence: resource["occurrence"] || 1,
        status: Invoice::STATUS[resource["status"]["code"].to_s],
        created_on_moip_at: date
      )
    end
  end
end

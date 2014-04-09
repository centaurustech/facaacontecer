module PaymentObserver
  extend ActiveSupport::Concern

  included do
    before_create :setup_code
    after_create  :send_created_payment_email_slip,   if: -> { self.subscription.slip? }
    after_create  :send_created_payment_email_debit,  if: -> { self.subscription.debit? }

    # SETUP an unique code for each payment, after its creation
    # All subscriptions have only integer code
    # All payments (except creditcard) have a PAYMENT suffix after the subscription code
    # E.g.:
    #   int: 123456        is the subscription
    #   int + string: 123456PAYMENT is the payment for boleto and debito
    #   int: 123123 is the payment for creditcard
    def setup_code
      self.code = "#{self.subscription.code}PAYMENT"
    end

    # Deliver an email with payment links when slip
    def send_created_payment_email_slip
      return false unless self.url
      Notifications::PaymentMailer.delay.created_payment_slip(self.id)
    end

    # Deliver an email with payment links when debit
    def send_created_payment_email_debit
      return false unless self.url
      Notifications::PaymentMailer.delay.created_payment_debit(self.id)
    end

    # Deliver an email informing that the payment is being processed
    def notify_user
      Notifications::PaymentMailer.delay.processing_payment(self.id)
    end

    # Deliver an email informating the user's INVITER that he won a prize
    # if present, of course
    def notify_inviter
      inviter = self.user.invite.host

      # TODO: Only send the notify inviter email once for
      if inviter and has_only_one_authorized_payment?
        Notifications::InviteMailer.delay.created_guest(self.user.id, inviter.id)
      end
    end

    def has_only_one_authorized_payment?
      Payment.where(state: :authorized, subscription: self.subscription).count.to_i == 1
    end

    # After the finish event for a payment, activate the parent subscription
    # And send activated_subscription_email
    def activate_subscription
      self.update_attribute(:paid_at, Time.now)
      self.subscription.activate!
      Notifications::PaymentMailer.delay.authorized_payment(self.id)
    end

    # After the Refund/ Reverse action in a payment, Pause the subscription
    # And send paused_subscription_email
    def pause_subscription
      self.subscription.pause!
    end

    # Notify a refund or reverse action when the user requests it
    def notify_refund
      nil
    end

    # Notify a user when a payment is cancelled
    def notify_cancelation
      Notifications::PaymentMailer.delay.cancelled_payment(self.id)
    end

    # TODO: add all users to the MC list
    def add_to_mailchimp_segment seg_id
      begin
        Gibbon::API.lists.static_segment_members_add(
          id: ENV["MAILCHIMP_LIST_ID"],
          seg_id: seg_id,
          batch: [{ email: self.user.email }]
        )
      rescue Exception => e
        Rails.logger.error e
      end
    end

    def remove_from_mailchimp_segment seg_id
      begin
        Gibbon::API.lists.static_segment_members_del(
          id: ENV["MAILCHIMP_LIST_ID"],
          seg_id: seg_id,
          batch: [{ email: self.user.email }]
        )
      rescue Exception => e
        Rails.logger.error e
      end
    end

    # Placing all callbacks inside the observer, instead of
    # Putting it on states file. This way we can keep things organized.
    # States where states should be; Callbacks (observers) where they should be as well.
    state_machine do
      after_transition on: :authorize,          do: [:activate_subscription, :notify_inviter]
      after_transition on: :cancel,             do: [:pause_subscription, :notify_cancelation]
      after_transition on: :wait,               do: [:notify_user]
      after_transition on: [:reverse, :refund], do: [:pause_subscription, :notify_refund]

      after_transition on: [:finish, :authorize] do |payment|
        payment.delay.add_to_mailchimp_segment ENV["MAILCHIMP_ACTIVE_SEG_ID"]
        payment.delay.remove_from_mailchimp_segment ENV["MAILCHIMP_INACTIVE_SEG_ID"]
      end

      after_transition on: :cancel do |payment|
        payment.delay.add_to_mailchimp_segment ENV["MAILCHIMP_INACTIVE_SEG_ID"]
        payment.delay.remove_from_mailchimp_segment ENV["MAILCHIMP_ACTIVE_SEG_ID"]
      end
    end
  end
end

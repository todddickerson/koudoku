module Koudoku::Subscription
  extend ActiveSupport::Concern

  included do

    # We don't store these one-time use tokens, but this is what Stripe provides
    # client-side after storing the credit card information.
    attr_accessor :credit_card_token
    
    belongs_to :plan

    # update details.
    before_save :processing!
    def processing!

      # if their package level has changed ..
      if changing_plans? 

        prepare_for_plan_change

        # and a customer exists in stripe ..
        if stripe_id.present?

          # fetch the customer.
          customer = Stripe::Customer.retrieve(self.stripe_id)

          # if a new plan has been selected
          if self.plan.present?

            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_downgrade if downgrading?
            prepare_for_upgrade if upgrading?

            sub = customer.subscriptions.first
            if sub && sub.trial_end && sub.trial_end > Time.now.to_i
              trial_end = sub.trial_end
              # update package level and adjust trial end to match current subscription trial_end + add starting plan trial
              stripe_plan = Stripe::Plan.retrieve(self.plan.stripe_id)
              if stripe_plan.trial_period_days
                trial_end = trial_end + stripe_plan.trial_period_days.to_i.days
              end
              customer.update_subscription(:plan => self.plan.stripe_id, trial_end: trial_end) if Koudoku.keep_trial_end
            else
              # update the package level with stripe.
              customer.update_subscription(:plan => self.plan.stripe_id)
            end

            finalize_downgrade! if downgrading?
            finalize_upgrade! if upgrading?

          # if no plan has been selected.
          else

            prepare_for_cancelation

            # Remove the current pricing.
            self.current_price = nil

            # delete the subscription. - at_period_end if prorate == false
            begin
              customer.cancel_subscription({:at_period_end => (!Koudoku.prorate).to_s })
            rescue => e
              logger.info "Error Canceling Stripe Subscription: #{e.to_s}"
              # assume already canceled by support
            end

            finalize_cancelation!

          end

        # otherwise
        else
          # if a new plan has been selected
          if self.plan.present?

            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_new_subscription
            prepare_for_upgrade

            begin

              customer_attributes = {
                description: subscription_owner_description,
                email: subscription_owner_email,
                card: credit_card_token, # obtained with Stripe.js
                plan: plan.stripe_id
              }

              # If the class we're being included in supports coupons ..
              if respond_to? :coupon
                if coupon.present? and coupon.free_trial?
                  customer_attributes[:trial_end] = coupon.free_trial_ends.to_i
                end
              end

              # create a customer at that package level.
              customer = Stripe::Customer.create(customer_attributes)
              
            rescue Stripe::CardError => card_error
              errors[:base] << card_error.message
              card_was_declined
              return false
            end

            # store the customer id.
            self.stripe_id = customer.id
            self.last_four = customer.cards.retrieve(customer.default_card).last4

            finalize_new_subscription!
            finalize_upgrade!

          else

            # This should never happen.

            self.plan_id = nil

            # Remove any plan pricing.
            self.current_price = nil

          end

        end

        finalize_plan_change!
        
      # if they're updating their credit card details.
      elsif self.credit_card_token.present?
        
        prepare_for_card_update
        
        # fetch the customer.
        customer = Stripe::Customer.retrieve(self.stripe_id)
        customer.card = self.credit_card_token
        customer.save

        # update the last four based on this new card.
        self.last_four = customer.cards.retrieve(customer.default_card).last4
        finalize_card_update!

      end

    end

  end

  module ClassMethods
  end

  def describe_difference(plan_to_describe)
    if plan.nil?
      if persisted?
        "Upgrade"
      else
        if Koudoku.free_trial?
          "Start Trial"
        else 
          "Upgrade"
        end
      end
    else
      if plan_to_describe.is_upgrade_from?(plan)
        "Upgrade"
      else
        "Downgrade"
      end
    end
  end

  # Pretty sure this wouldn't conflict with anything someone would put in their model
  def subscription_owner
    # Return whatever we belong to.
    # If this object doesn't respond to 'name', please update owner_description.
    send Koudoku.subscriptions_owned_by
  end

  def subscription_owner_description
    # assuming owner responds to name.
    # we should check for whether it responds to this or not.
    "#{subscription_owner.id} - #{subscription_owner.try(:email).to_s} - #{subscription_owner.try(:name).to_s} - #{subscription_owner.try(:phone).to_s}"
  end

  def subscription_owner_email
    "#{subscription_owner.try(:email).to_s}"
  end

  def changing_plans?
    plan_id_changed?
  end

  def downgrading?
    plan.present? and plan_id_was.present? and plan_id_was > self.plan_id
  end

  def upgrading?
    (plan_id_was.present? and plan_id_was < plan_id) or plan_id_was.nil?
  end

  # Template methods.
  def prepare_for_plan_change
  end

  def prepare_for_new_subscription
  end

  def prepare_for_upgrade
  end

  def prepare_for_downgrade
  end

  def prepare_for_cancelation
  end
  
  def prepare_for_card_update
  end

  def finalize_plan_change!
  end

  def finalize_new_subscription!
  end

  def finalize_upgrade!
  end

  def finalize_downgrade!
  end

  def finalize_cancelation!
  end

  def finalize_card_update!
  end

  def card_was_declined
  end
  
  # stripe web-hook callbacks.
  def payment_succeeded(amount)
  end
  
  def charge_failed
  end
  
  def charge_disputed
  end

end

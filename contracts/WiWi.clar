;; WiWi Subscription Contract
;; Manages recurring subscriptions with STX payments

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant MIN_RATE u1000000) ;; 1 STX minimum (1,000,000 microSTX)
(define-constant RENEWAL_PERIOD u10080) ;; ~7 days in blocks

;; New Security Constants
(define-constant MAX_RATE u100000000) ;; 100 STX maximum rate
(define-constant RATE_CHANGE_COOLDOWN u1440) ;; 1 day cooldown for rate changes
(define-constant EMERGENCY_PAUSE_DURATION u144000) ;; ~100 days max pause
(define-constant MAX_SUBSCRIPTIONS_PER_USER u10) ;; Prevent spam

;; Error codes
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_RATE (err u101))
(define-constant ERR_TRANSFER_FAILED (err u102))
(define-constant ERR_NOT_EXPIRED (err u103))
(define-constant ERR_NO_SUBSCRIPTION (err u104))

;; New Security Error Codes
(define-constant ERR_RATE_TOO_HIGH (err u105))
(define-constant ERR_RATE_CHANGE_COOLDOWN (err u106))
(define-constant ERR_CONTRACT_PAUSED (err u107))
(define-constant ERR_MAX_SUBSCRIPTIONS_REACHED (err u108))
(define-constant ERR_INVALID_RECEIVER (err u109))
(define-constant ERR_SELF_SUBSCRIPTION (err u110))
(define-constant ERR_SUBSCRIPTION_EXISTS (err u111))

;; Data maps
(define-map subscriptions uint
  { subscriber: principal, receiver: principal, expiry: uint, rate: uint })
(define-map subscription-index
  { subscriber: principal, receiver: principal } uint)

;; New Security Data Maps
(define-map authorized-operators principal bool)
(define-map user-subscription-count principal uint)
(define-map rate-change-history uint uint) ;; Last rate change block per subscription

;; Contract State Variables
(define-data-var contract-paused bool false)
(define-data-var pause-end-block uint u0)
(define-data-var total-volume uint u0)
(define-data-var next-subscription-id uint u1)

;; Events
(define-private (log-subscription-created (subscription-id uint) (subscriber principal) (receiver principal) (rate uint) (expiry uint))
  (print {
    event: "subscription-created",
    subscription-id: subscription-id,
    subscriber: subscriber,
    receiver: receiver,
    rate: rate,
    expiry: expiry
  }))

(define-private (log-subscription-renewed (subscription-id uint) (subscriber principal) (receiver principal) (rate uint) (new-expiry uint))
  (print {
    event: "subscription-renewed",
    subscription-id: subscription-id,
    subscriber: subscriber,
    receiver: receiver,
    rate: rate,
    new-expiry: new-expiry
  }))

(define-private (log-subscription-cancelled (subscription-id uint) (subscriber principal) (cancelled-by principal))
  (print {
    event: "subscription-cancelled",
    subscription-id: subscription-id,
    subscriber: subscriber,
    cancelled-by: cancelled-by
  }))

;; New Security Event
(define-private (log-security-event (event-type (string-ascii 50)) (details (string-ascii 100)))
  (print {
    event: "security-event",
    type: event-type,
    details: details,
    block: stacks-block-height
  }))

;; Enhanced subscription function with security checks
(define-public (subscribe (receiver principal) (rate uint) (period uint))
  (let ((expiry (+ stacks-block-height period))
        (current-user-subs (default-to u0 (map-get? user-subscription-count tx-sender)))
        (existing-subscription (map-get? subscription-index { subscriber: tx-sender, receiver: receiver }))
        (subscription-id (var-get next-subscription-id)))
    (begin
      ;; Security checks
      (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
      (asserts! (not (is-eq tx-sender receiver)) ERR_SELF_SUBSCRIPTION)
      (asserts! (< current-user-subs MAX_SUBSCRIPTIONS_PER_USER) ERR_MAX_SUBSCRIPTIONS_REACHED)
      
      ;; Enhanced rate validation
      (asserts! (>= rate MIN_RATE) ERR_INSUFFICIENT_RATE)
      (asserts! (<= rate MAX_RATE) ERR_RATE_TOO_HIGH)
      
      ;; Check if subscription already exists
      (asserts! (is-none existing-subscription) ERR_SUBSCRIPTION_EXISTS)
      
      ;; Make initial payment - must succeed
      (unwrap! (stx-transfer? rate tx-sender receiver) ERR_TRANSFER_FAILED)
      
      ;; Update volume tracking
      (var-set total-volume (+ (var-get total-volume) rate))
      
      ;; Store subscription
      (map-set subscriptions subscription-id { 
        subscriber: tx-sender,
        receiver: receiver,
        expiry: expiry, 
        rate: rate 
      })
      (map-set subscription-index { subscriber: tx-sender, receiver: receiver } subscription-id)
      
      ;; Update user subscription count
      (map-set user-subscription-count tx-sender (+ current-user-subs u1))
      (var-set next-subscription-id (+ subscription-id u1))
      
      ;; Log event
      (log-subscription-created subscription-id tx-sender receiver rate expiry)
      
      (ok subscription-id))))

;; Original renew function with security enhancements
(define-public (renew (subscription-id uint))
  (let ((sub (unwrap! (map-get? subscriptions subscription-id) ERR_NO_SUBSCRIPTION)))
    (let ((subscriber (get subscriber sub))
          (expiry (get expiry sub)) 
          (rate (get rate sub)) 
          (receiver (get receiver sub))
          (new-expiry (+ stacks-block-height RENEWAL_PERIOD)))
      (begin
        ;; Security check
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-eq subscriber tx-sender) ERR_UNAUTHORIZED)
        
        ;; Check if subscription has expired
        (asserts! (>= stacks-block-height expiry) ERR_NOT_EXPIRED)
        
        ;; Make renewal payment - must succeed
        (unwrap! (stx-transfer? rate tx-sender receiver) ERR_TRANSFER_FAILED)
        
        ;; Update volume tracking
        (var-set total-volume (+ (var-get total-volume) rate))
        
        ;; Update subscription
        (map-set subscriptions subscription-id { 
          subscriber: subscriber,
          receiver: receiver,
          expiry: new-expiry, 
          rate: rate 
        })
        
        ;; Log event
        (log-subscription-renewed subscription-id subscriber receiver rate new-expiry)
        
        (ok true)))))

;; New function to change subscription rate with security
(define-public (change-subscription-rate (subscription-id uint) (new-rate uint))
  (let ((sub (unwrap! (map-get? subscriptions subscription-id) ERR_NO_SUBSCRIPTION)))
    (begin
      ;; Security checks
      (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
      (asserts! (is-eq (get subscriber sub) tx-sender) ERR_UNAUTHORIZED)
      (asserts! (>= new-rate MIN_RATE) ERR_INSUFFICIENT_RATE)
      (asserts! (<= new-rate MAX_RATE) ERR_RATE_TOO_HIGH)
      
      ;; Check cooldown period
      (let ((cooldown-ok
              (match (map-get? rate-change-history subscription-id)
                last-change (>= stacks-block-height (+ last-change RATE_CHANGE_COOLDOWN))
                true)))
        (asserts! cooldown-ok ERR_RATE_CHANGE_COOLDOWN))
      
      ;; Update subscription with new rate
      (map-set subscriptions subscription-id {
        subscriber: (get subscriber sub),
        receiver: (get receiver sub),
        expiry: (get expiry sub),
        rate: new-rate
      })
      
      ;; Record rate change
      (map-set rate-change-history subscription-id stacks-block-height)
      
      ;; Log security event
      (log-security-event "rate-changed" "subscription-rate-updated")
      
      (ok true))))

;; Emergency pause function (owner only)
(define-public (emergency-pause (duration uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= duration EMERGENCY_PAUSE_DURATION) ERR_UNAUTHORIZED)
    
    (var-set contract-paused true)
    (var-set pause-end-block (+ stacks-block-height duration))
    
    (log-security-event "contract-paused" "emergency-pause-activated")
    
    (ok true)))

;; Unpause function (owner only or automatic after duration)
(define-public (unpause-contract)
  (begin
    (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                  (>= stacks-block-height (var-get pause-end-block))) ERR_UNAUTHORIZED)
    
    (var-set contract-paused false)
    (var-set pause-end-block u0)
    
    (log-security-event "contract-unpaused" "contract-operations-resumed")
    
    (ok true)))

;; Operator management (owner only)
(define-public (add-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set authorized-operators operator true)
    (log-security-event "operator-added" "new-operator-authorized")
    (ok true)))

(define-public (remove-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-delete authorized-operators operator)
    (log-security-event "operator-removed" "operator-authorization-revoked")
    (ok true)))

;; Admin function to cancel any subscription (enhanced)
(define-public (admin-cancel-subscription (subscription-id uint))
  (let ((sub (unwrap! (map-get? subscriptions subscription-id) ERR_NO_SUBSCRIPTION))
        (subscriber (get subscriber sub))
        (receiver (get receiver sub))
        (current-count (default-to u0 (map-get? user-subscription-count subscriber))))
    (begin
      ;; Only contract owner or authorized operators can cancel subscriptions
      (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                    (default-to false (map-get? authorized-operators tx-sender))) ERR_UNAUTHORIZED)
      
      ;; Remove subscription
      (map-delete subscriptions subscription-id)
      (map-delete subscription-index { subscriber: subscriber, receiver: receiver })
      
      ;; Update user subscription count
      (if (> current-count u0)
        (map-set user-subscription-count subscriber (- current-count u1))
        true)
      
      ;; Clean up rate change history
      (map-delete rate-change-history subscription-id)
      
      ;; Log event
      (log-subscription-cancelled subscription-id subscriber tx-sender)
      (log-security-event "admin-cancellation" "subscription-cancelled-by-admin")
      
      (ok true))))

;; Enhanced user function to cancel own subscription
(define-public (cancel-subscription (subscription-id uint))
  (let ((sub (unwrap! (map-get? subscriptions subscription-id) ERR_NO_SUBSCRIPTION))
        (subscriber (get subscriber sub))
        (receiver (get receiver sub))
        (current-count (default-to u0 (map-get? user-subscription-count tx-sender))))
    (begin
      ;; Ensure caller owns the subscription
      (asserts! (is-eq subscriber tx-sender) ERR_UNAUTHORIZED)
      
      ;; Remove subscription
      (map-delete subscriptions subscription-id)
      (map-delete subscription-index { subscriber: subscriber, receiver: receiver })
      
      ;; Update user subscription count
      (if (> current-count u0)
        (map-set user-subscription-count tx-sender (- current-count u1))
        true)
      
      ;; Clean up rate change history
      (map-delete rate-change-history subscription-id)
      
      ;; Log event
      (log-subscription-cancelled subscription-id tx-sender tx-sender)
      
      (ok true))))

;; Read-only functions (original)
(define-read-only (get-subscription (subscription-id uint))
  (map-get? subscriptions subscription-id))

(define-read-only (get-subscription-id (subscriber principal) (receiver principal))
  (map-get? subscription-index { subscriber: subscriber, receiver: receiver }))

(define-read-only (get-subscription-by-receiver (subscriber principal) (receiver principal))
  (match (map-get? subscription-index { subscriber: subscriber, receiver: receiver })
    subscription-id (map-get? subscriptions subscription-id)
    none))

(define-read-only (is-subscription-active (subscription-id uint))
  (match (map-get? subscriptions subscription-id)
    sub-val (> (get expiry sub-val) stacks-block-height)
    false))

(define-read-only (get-contract-owner)
  CONTRACT_OWNER)

(define-read-only (get-min-rate)
  MIN_RATE)

;; New security read-only functions
(define-read-only (get-max-rate)
  MAX_RATE)

(define-read-only (is-contract-paused)
  (var-get contract-paused))

(define-read-only (get-pause-end-block)
  (var-get pause-end-block))

(define-read-only (is-authorized-operator (operator principal))
  (default-to false (map-get? authorized-operators operator)))

(define-read-only (get-user-subscription-count (user principal))
  (default-to u0 (map-get? user-subscription-count user)))

(define-read-only (get-total-volume)
  (var-get total-volume))

(define-read-only (can-change-rate (subscription-id uint))
  (match (map-get? rate-change-history subscription-id)
    last-change (>= stacks-block-height (+ last-change RATE_CHANGE_COOLDOWN))
    true))

(define-read-only (get-rate-change-cooldown-remaining (subscription-id uint))
  (match (map-get? rate-change-history subscription-id)
    last-change (let ((cooldown-end (+ last-change RATE_CHANGE_COOLDOWN)))
                  (if (>= stacks-block-height cooldown-end)
                    u0
                    (- cooldown-end stacks-block-height)))
    u0))

(define-read-only (get-subscription-limits)
  {
    min-rate: MIN_RATE,
    max-rate: MAX_RATE,
    max-subscriptions-per-user: MAX_SUBSCRIPTIONS_PER_USER,
    rate-change-cooldown: RATE_CHANGE_COOLDOWN,
    renewal-period: RENEWAL_PERIOD
  })

;; WiWi Subscription Contract
;; Manages recurring subscriptions with STX payments

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant MIN_RATE u1000000) ;; 1 STX minimum (1,000,000 microSTX)
(define-constant RENEWAL_PERIOD u10080) ;; ~7 days in blocks

;; Error codes
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_RATE (err u101))
(define-constant ERR_TRANSFER_FAILED (err u102))
(define-constant ERR_NOT_EXPIRED (err u103))
(define-constant ERR_NO_SUBSCRIPTION (err u104))

;; Data maps
(define-map subscriptions principal
  { expiry: uint, rate: uint, receiver: principal })

;; Events
(define-private (log-subscription-created (subscriber principal) (receiver principal) (rate uint) (expiry uint))
  (print {
    event: "subscription-created",
    subscriber: subscriber,
    receiver: receiver,
    rate: rate,
    expiry: expiry
  }))

(define-private (log-subscription-renewed (subscriber principal) (receiver principal) (rate uint) (new-expiry uint))
  (print {
    event: "subscription-renewed",
    subscriber: subscriber,
    receiver: receiver,
    rate: rate,
    new-expiry: new-expiry
  }))

(define-private (log-subscription-cancelled (subscriber principal) (cancelled-by principal))
  (print {
    event: "subscription-cancelled",
    subscriber: subscriber,
    cancelled-by: cancelled-by
  }))

;; Public functions
(define-public (subscribe (receiver principal) (rate uint) (period uint))
  (let ((expiry (+ stacks-block-height period)))
    (begin
      ;; Validate minimum rate
      (asserts! (>= rate MIN_RATE) ERR_INSUFFICIENT_RATE)
      
      ;; Make initial payment - must succeed
      (unwrap! (stx-transfer? rate tx-sender receiver) ERR_TRANSFER_FAILED)
      
      ;; Store subscription
      (map-set subscriptions tx-sender { 
        expiry: expiry, 
        rate: rate, 
        receiver: receiver 
      })
      
      ;; Log event
      (log-subscription-created tx-sender receiver rate expiry)
      
      (ok true))))

(define-public (renew)
  (let ((sub (unwrap! (map-get? subscriptions tx-sender) ERR_NO_SUBSCRIPTION)))
    (let ((expiry (get expiry sub)) 
          (rate (get rate sub)) 
          (receiver (get receiver sub))
          (new-expiry (+ stacks-block-height RENEWAL_PERIOD)))
      (begin
        ;; Check if subscription has expired
        (asserts! (>= stacks-block-height expiry) ERR_NOT_EXPIRED)
        
        ;; Make renewal payment - must succeed
        (unwrap! (stx-transfer? rate tx-sender receiver) ERR_TRANSFER_FAILED)
        
        ;; Update subscription
        (map-set subscriptions tx-sender { 
          expiry: new-expiry, 
          rate: rate, 
          receiver: receiver 
        })
        
        ;; Log event
        (log-subscription-renewed tx-sender receiver rate new-expiry)
        
        (ok true)))))

;; Admin function to cancel any subscription
(define-public (admin-cancel-subscription (subscriber principal))
  (begin
    ;; Only contract owner can cancel subscriptions
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    
    ;; Check subscription exists
    (asserts! (is-some (map-get? subscriptions subscriber)) ERR_NO_SUBSCRIPTION)
    
    ;; Remove subscription
    (map-delete subscriptions subscriber)
    
    ;; Log event
    (log-subscription-cancelled subscriber tx-sender)
    
    (ok true)))

;; User function to cancel own subscription
(define-public (cancel-subscription)
  (begin
    ;; Check subscription exists
    (asserts! (is-some (map-get? subscriptions tx-sender)) ERR_NO_SUBSCRIPTION)
    
    ;; Remove subscription
    (map-delete subscriptions tx-sender)
    
    ;; Log event
    (log-subscription-cancelled tx-sender tx-sender)
    
    (ok true)))

;; Read-only functions
(define-read-only (get-subscription (subscriber principal))
  (map-get? subscriptions subscriber))

(define-read-only (is-subscription-active (subscriber principal))
  (match (map-get? subscriptions subscriber)
    sub-val (> (get expiry sub-val) stacks-block-height)
    false))

(define-read-only (get-contract-owner)
  CONTRACT_OWNER)

(define-read-only (get-min-rate)
  MIN_RATE)
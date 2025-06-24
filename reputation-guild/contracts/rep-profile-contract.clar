;; DeFi Reputation Guild - Stage 1: Basic Honor System
;; Simple honor-based lending with basic reputation tracking

;; Constants
(define-constant GUILD_MASTER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_HONOR (err u101))
(define-constant ERR_MEMBER_NOT_FOUND (err u102))
(define-constant ERR_LOAN_NOT_FOUND (err u103))
(define-constant ERR_LOAN_ALREADY_ACTIVE (err u104))

;; Minimum honor required for loans
(define-constant MIN_HONOR_REQUIRED u500)

;; Basic loan multiplier
(define-constant LOAN_MULTIPLIER u50)

;; Guild Variables
(define-data-var guild-active bool true)
(define-data-var total-loans uint u0)

;; Simple Member Profiles
(define-map member-profiles
  { member: principal }
  {
    honor-score: uint,
    total-loans: uint,
    successful-repayments: uint,
    failed-repayments: uint,
    last-updated: uint
  }
)

;; Basic Loan Records
(define-map active-loans
  { loan-id: uint }
  {
    borrower: principal,
    amount: uint,
    interest-rate: uint,
    blocks-duration: uint,
    start-block: uint,
    status: (string-ascii 20)
  }
)

;; Oracle authorization
(define-map authorized-oracles
  { oracle: principal }
  { active: bool }
)

;; Read-only functions

;; Get member honor score
(define-read-only (get-honor-score (member principal))
  (match (map-get? member-profiles { member: member })
    profile (ok (get honor-score profile))
    (err ERR_MEMBER_NOT_FOUND)
  )
)

;; Get member profile
(define-read-only (get-member-profile (member principal))
  (map-get? member-profiles { member: member })
)

;; Calculate maximum loan amount
(define-read-only (get-max-loan-amount (member principal))
  (match (get-honor-score member)
    honor-score (if (>= honor-score MIN_HONOR_REQUIRED)
                   (ok (* honor-score LOAN_MULTIPLIER))
                   (ok u0))
    error-code (err error-code)
  )
)

;; Get loan details
(define-read-only (get-loan-details (loan-id uint))
  (map-get? active-loans { loan-id: loan-id })
)

;; Check loan eligibility
(define-read-only (check-loan-eligibility (member principal) (amount uint))
  (match (get-honor-score member)
    honor-score (and 
                 (>= honor-score MIN_HONOR_REQUIRED)
                 (match (get-max-loan-amount member)
                   max-loan (>= max-loan amount)
                   error-code false))
    error-code false
  )
)

;; Private functions

;; Calculate interest rate based on honor score
(define-private (calculate-interest-rate (honor-score uint))
  (if (>= honor-score u800)
      u5   ;; 5% for high honor
      (if (>= honor-score u650)
          u8   ;; 8% for medium honor
          u12  ;; 12% for low honor
      )
  )
)

;; Public functions

;; Initialize or update member profile
(define-public (update-member-honor (member principal) (new-honor uint))
  (begin
    (asserts! (default-to false (get active (map-get? authorized-oracles { oracle: tx-sender }))) ERR_NOT_AUTHORIZED)
    (ok (map-set member-profiles
      { member: member }
      (merge 
        (default-to 
          { honor-score: u0, total-loans: u0, successful-repayments: u0, failed-repayments: u0, last-updated: u0 }
          (map-get? member-profiles { member: member }))
        { 
          honor-score: new-honor,
          last-updated: block-height
        }
      )
    ))
  )
)

;; Request a loan
(define-public (request-loan (amount uint) (duration-blocks uint))
  (let (
    (loan-id (+ (var-get total-loans) u1))
    (member-honor (unwrap! (get-honor-score tx-sender) ERR_MEMBER_NOT_FOUND))
    (interest-rate (calculate-interest-rate member-honor))
  )
  (asserts! (var-get guild-active) ERR_NOT_AUTHORIZED)
  (asserts! (check-loan-eligibility tx-sender amount) ERR_INSUFFICIENT_HONOR)
  (asserts! (is-none (map-get? active-loans { loan-id: loan-id })) ERR_LOAN_ALREADY_ACTIVE)
  
  ;; Create loan record
  (map-set active-loans
    { loan-id: loan-id }
    {
      borrower: tx-sender,
      amount: amount,
      interest-rate: interest-rate,
      blocks-duration: duration-blocks,
      start-block: block-height,
      status: "active"
    }
  )
  
  ;; Update member profile
  (map-set member-profiles
    { member: tx-sender }
    (merge 
      (default-to 
        { honor-score: u0, total-loans: u0, successful-repayments: u0, failed-repayments: u0, last-updated: u0 }
        (map-get? member-profiles { member: tx-sender }))
      { 
        total-loans: (+ (default-to u0 (get total-loans (map-get? member-profiles { member: tx-sender }))) u1)
      }
    )
  )
  
  ;; Update guild stats
  (var-set total-loans loan-id)
  
  (ok loan-id)
  )
)

;; Repay a loan
(define-public (repay-loan (loan-id uint))
  (let (
    (loan (unwrap! (map-get? active-loans { loan-id: loan-id }) ERR_LOAN_NOT_FOUND))
    (borrower (get borrower loan))
    (amount (get amount loan))
    (interest-rate (get interest-rate loan))
    (start-block (get start-block loan))
    (blocks-elapsed (- block-height start-block))
    (interest-amount (/ (* amount interest-rate blocks-elapsed) u100000))
    (total-repayment (+ amount interest-amount))
  )
  (asserts! (is-eq tx-sender borrower) ERR_NOT_AUTHORIZED)
  (asserts! (is-eq (get status loan) "active") ERR_LOAN_NOT_FOUND)
  
  ;; Update loan status
  (map-set active-loans
    { loan-id: loan-id }
    (merge loan { status: "repaid" })
  )
  
  ;; Update member profile
  (map-set member-profiles
    { member: tx-sender }
    (merge 
      (default-to 
        { honor-score: u0, total-loans: u0, successful-repayments: u0, failed-repayments: u0, last-updated: u0 }
        (map-get? member-profiles { member: tx-sender }))
      { 
        successful-repayments: (+ (default-to u0 (get successful-repayments (map-get? member-profiles { member: tx-sender }))) u1)
      }
    )
  )
  
  (ok total-repayment)
  )
)

;; Authorize oracle
(define-public (authorize-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender GUILD_MASTER) ERR_NOT_AUTHORIZED)
    (ok (map-set authorized-oracles
      { oracle: oracle }
      { active: true }
    ))
  )
)

;; Revoke oracle authorization
(define-public (revoke-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender GUILD_MASTER) ERR_NOT_AUTHORIZED)
    (ok (map-set authorized-oracles
      { oracle: oracle }
      { active: false }
    ))
  )
)

;; Toggle guild status
(define-public (toggle-guild-status)
  (begin
    (asserts! (is-eq tx-sender GUILD_MASTER) ERR_NOT_AUTHORIZED)
    (ok (var-set guild-active (not (var-get guild-active))))
  )
)
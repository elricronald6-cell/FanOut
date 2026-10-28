// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FanOut
 * @notice Two-level referral attribution on BOT Chain.
 *
 * A campaign owner sets two commission rates: one for whoever referred a
 * contributor, and one for whoever referred *them*. Every contribution splits
 * itself at the moment it arrives — no reconciliation, no owner signing off on
 * who introduced whom, no off-chain tracking pixel.
 *
 * Two deliberate choices:
 *
 *  1. **Attribution is permanent.** The first join fixes your referrer for
 *     that campaign forever. Later contributions pay the same two people.
 *     Nobody can be re-attributed by a later transaction.
 *  2. **Unearned commission goes back to the campaign, not to the protocol.**
 *     A contributor with no referrer, or a referrer with no referrer of their
 *     own, simply leaves more in the campaign vault. The platform's cut is
 *     `feeBps` and nothing else.
 *
 * Commissions are pull-based: they accrue to a balance the earner withdraws,
 * so one bad recipient can never block somebody else's contribution.
 */
contract FanOut is Ownable, Pausable, ReentrancyGuard {
    struct Campaign {
        address owner;
        uint256 vault;
        uint16 l1Bps;
        uint16 l2Bps;
        uint256 minContribution;
        bool open;
        uint32 participants;
        uint256 totalIn;
        string name;
    }

    uint16 public constant MAX_COMMISSION_BPS = 4000;
    uint16 public constant MAX_FEE_BPS = 500;
    uint256 public constant MAX_NAME = 56;

    /// @notice Protocol cut of each contribution.
    uint16 public feeBps = 200;

    uint256 public accumulatedFees;
    /// @notice Vault balances plus unclaimed commission.
    uint256 public lockedTotal;

    Campaign[] private _campaigns;

    mapping(uint256 => mapping(address => address)) private _referrerOf;
    mapping(uint256 => mapping(address => bool)) private _joined;
    mapping(uint256 => mapping(address => uint256)) private _earned;
    mapping(uint256 => mapping(address => uint256)) private _contributed;
    mapping(uint256 => mapping(address => address[])) private _children;
    mapping(address => uint256[]) private _campaignsByOwner;

    event CampaignCreated(uint256 indexed id, address indexed owner, string name, uint16 l1Bps, uint16 l2Bps, uint256 minContribution);
    event CampaignOpenSet(uint256 indexed id, bool open);
    event Joined(uint256 indexed id, address indexed who, address indexed referrer);
    event Contributed(uint256 indexed id, address indexed who, uint256 amount, uint256 l1, uint256 l2, uint256 toVault, uint256 fee);
    event EarningsWithdrawn(uint256 indexed id, address indexed who, uint256 amount);
    event VaultWithdrawn(uint256 indexed id, address indexed owner, uint256 amount);
    event FeeUpdated(uint16 feeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // ----------------------------------------------------------- campaigns

    function createCampaign(string calldata name, uint16 l1Bps, uint16 l2Bps, uint256 minContribution)
        external
        whenNotPaused
        returns (uint256 id)
    {
        require(bytes(name).length > 0 && bytes(name).length <= MAX_NAME, "bad name");
        require(uint256(l1Bps) + l2Bps <= MAX_COMMISSION_BPS, "commission too high");
        require(l1Bps >= l2Bps, "l2 above l1");
        require(minContribution > 0, "min must be positive");

        id = _campaigns.length;
        _campaigns.push(
            Campaign({
                owner: msg.sender,
                vault: 0,
                l1Bps: l1Bps,
                l2Bps: l2Bps,
                minContribution: minContribution,
                open: true,
                participants: 0,
                totalIn: 0,
                name: name
            })
        );
        _campaignsByOwner[msg.sender].push(id);
        emit CampaignCreated(id, msg.sender, name, l1Bps, l2Bps, minContribution);
    }

    function setOpen(uint256 id, bool open) external {
        Campaign storage c = _campaign(id);
        require(c.owner == msg.sender, "not campaign owner");
        c.open = open;
        emit CampaignOpenSet(id, open);
    }

    // ---------------------------------------------------------- joining in

    /**
     * @notice Contribute to a campaign, optionally crediting a referrer.
     * @param referrer Must already be a participant of this campaign. Pass the
     *        zero address for no referrer. Ignored on every contribution after
     *        the first — attribution is fixed by the first one.
     */
    function join(uint256 id, address referrer) external payable nonReentrant whenNotPaused {
        Campaign storage c = _campaign(id);
        require(c.open, "campaign closed");
        require(msg.value >= c.minContribution, "below minimum");
        require(msg.sender != c.owner, "owner cannot join");

        if (!_joined[id][msg.sender]) {
            if (referrer != address(0)) {
                require(referrer != msg.sender, "cannot refer yourself");
                require(_joined[id][referrer], "referrer not in campaign");
                _referrerOf[id][msg.sender] = referrer;
                _children[id][referrer].push(msg.sender);
            }
            _joined[id][msg.sender] = true;
            unchecked {
                c.participants += 1;
            }
            emit Joined(id, msg.sender, _referrerOf[id][msg.sender]);
        }

        uint256 amount = msg.value;
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 l1Amount;
        uint256 l2Amount;

        address l1 = _referrerOf[id][msg.sender];
        if (l1 != address(0)) {
            l1Amount = (amount * c.l1Bps) / 10_000;
            _earned[id][l1] += l1Amount;

            address l2 = _referrerOf[id][l1];
            if (l2 != address(0) && l2 != msg.sender) {
                l2Amount = (amount * c.l2Bps) / 10_000;
                _earned[id][l2] += l2Amount;
            }
        }

        // Whatever commission was not earned stays with the campaign.
        uint256 toVault = amount - fee - l1Amount - l2Amount;
        c.vault += toVault;
        c.totalIn += amount;
        _contributed[id][msg.sender] += amount;

        accumulatedFees += fee;
        lockedTotal += (amount - fee);

        emit Contributed(id, msg.sender, amount, l1Amount, l2Amount, toVault, fee);
    }

    // ------------------------------------------------------------ payouts

    /// @dev Allowed while paused. Earned money is never held hostage.
    function withdrawEarnings(uint256 id) external nonReentrant {
        _campaign(id);
        uint256 amount = _earned[id][msg.sender];
        require(amount > 0, "nothing earned");
        _earned[id][msg.sender] = 0;
        lockedTotal -= amount;
        emit EarningsWithdrawn(id, msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function withdrawVault(uint256 id) external nonReentrant {
        Campaign storage c = _campaign(id);
        require(c.owner == msg.sender, "not campaign owner");
        uint256 amount = c.vault;
        require(amount > 0, "vault empty");
        c.vault = 0;
        lockedTotal -= amount;
        emit VaultWithdrawn(id, msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // --------------------------------------------------------------- views

    function campaignCount() external view returns (uint256) {
        return _campaigns.length;
    }

    function getCampaign(uint256 id) external view returns (Campaign memory) {
        return _campaign(id);
    }

    function referrerOf(uint256 id, address who) external view returns (address) {
        return _referrerOf[id][who];
    }

    function earnedBy(uint256 id, address who) external view returns (uint256) {
        return _earned[id][who];
    }

    function contributedBy(uint256 id, address who) external view returns (uint256) {
        return _contributed[id][who];
    }

    function hasJoined(uint256 id, address who) external view returns (bool) {
        return _joined[id][who];
    }

    /// @notice The addresses this wallet brought in directly.
    function directReferrals(uint256 id, address who) external view returns (address[] memory) {
        return _children[id][who];
    }

    /// @notice Both levels above a wallet, as (l1, l2).
    function uplineOf(uint256 id, address who) external view returns (address l1, address l2) {
        l1 = _referrerOf[id][who];
        if (l1 != address(0)) l2 = _referrerOf[id][l1];
    }

    function getCampaignsByOwner(address owner) external view returns (uint256[] memory) {
        return _campaignsByOwner[owner];
    }

    /// @notice Newest-first page of campaign ids.
    function getRecent(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _campaigns.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    /// @notice How a contribution of `amount` would split in this campaign, for this sender.
    function previewSplit(uint256 id, address who, uint256 amount)
        external
        view
        returns (uint256 l1Amount, uint256 l2Amount, uint256 toVault, uint256 fee)
    {
        Campaign storage c = _campaign(id);
        fee = (amount * feeBps) / 10_000;
        address l1 = _referrerOf[id][who];
        if (l1 != address(0)) {
            l1Amount = (amount * c.l1Bps) / 10_000;
            address l2 = _referrerOf[id][l1];
            if (l2 != address(0) && l2 != who) l2Amount = (amount * c.l2Bps) / 10_000;
        }
        toVault = amount - fee - l1Amount - l2Amount;
    }

    // --------------------------------------------------------------- admin

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`. Vaults and commissions are unreachable.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _campaign(uint256 id) private view returns (Campaign storage) {
        require(id < _campaigns.length, "no such campaign");
        return _campaigns[id];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}

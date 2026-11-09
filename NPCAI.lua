-- Discord: alentiks (Loydxx) | Roblox: (Loyd) TheyWantDestroyMe
-- LOYD FRAMEWORK | Server-authoritative NPC combat, navigation, and lifecycle management.
-- Architecture: each NPC owns runtime state; shared methods/configuration prevent duplicated implementations.
-- Security: target selection, path decisions, and damage are performed by the server.

--services
local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

-- CONFIGURATION: balance values stay separate from the algorithms that consume them.
-- Central tuning table separates balancing from behavior algorithms.
local CONFIG = {
	NPCModelName = "NPCModel", -- Template model stored in ServerStorage.
	NPCFolderName = "LoydNPCs", -- Workspace container for runtime NPC clones.
	NPCCount = 3, -- Number of NPC controllers created at startup.
	SpawnRadius = 24, -- Horizontal distance from the arena origin to each spawn point.
	SpawnHeight = 3, -- Vertical offset that keeps spawned rigs above the floor.
	DetectionRadius = 80, -- Maximum range for acquiring a new player target.
	LoseTargetRadius = 105, -- Larger release radius prevents target flicker near the acquisition boundary.
	FieldOfViewDegrees = 220, -- Total horizontal viewing cone used during acquisition.
	RequireLineOfSight = true, -- When true, geometry blocks target acquisition.
	WalkSpeed = 12, -- Speed used for patrol and returning home.
	ChaseSpeed = 18, -- Speed used while pursuing a player.
	AttackRange = 5.5, -- Maximum distance allowed when an attack begins.
	AttackDamage = 18, -- Server-applied damage after delayed validation succeeds.
	AttackCooldown = 1.4, -- Minimum interval between attack starts.
	AttackWindup = 0.25, -- Delay before final damage validation.
	AttackFacingDot = 0.35, -- Minimum forward alignment required to land a hit.
	PathRecomputeInterval = 1.1, -- Minimum interval between route calculations.
	TargetMoveThreshold = 7, -- Target displacement that invalidates the cached route.
	WaypointReachedDistance = 3, -- Distance threshold for completing a destination.
	StuckCheckInterval = 1.5, -- Time between movement-progress samples.
	StuckDistanceThreshold = 1.25, -- Minimum expected displacement per sample.
	StuckRepathLimit = 3, -- Consecutive stalled samples before jump recovery.
	PatrolRadius = 18, -- Maximum patrol distance from the spawn point.
	PatrolWaitMin = 1, -- Shortest pause between patrol destinations.
	PatrolWaitMax = 3, -- Longest pause between patrol destinations.
	ThinkInterval = 0.15, -- Delay between decisions; physics continues between updates.
	RespawnDelay = 5, -- Delay before a defeated NPC is replaced.
	AgentRadius = 2, -- Pathfinding clearance radius matched to the rig.
	AgentHeight = 5, -- Pathfinding clearance height matched to the rig.
	AgentCanJump = true, -- Allows generated paths to include jump waypoints.
	AgentJumpHeight = 8, -- Maximum jump height considered by pathfinding.
	AgentMaxSlope = 35, -- Maximum traversable slope angle.
}
-- TYPES: constrain state names and document the controller data contract.
type AIState = "Idle" | "Patrol" | "Chase" | "Attack" | "Return" | "Dead"
type NPCConfig = {
	DetectionRadius: number,
	LoseTargetRadius: number,
	AttackRange: number,
	AttackDamage: number,
	AttackCooldown: number,
	WalkSpeed: number,
	ChaseSpeed: number,
}
type NPCController = {
	Model: Model, -- Controlled NPC model.
	Humanoid: Humanoid, -- Health and movement component.
	Root: BasePart, -- Root part for spatial calculations.
	SpawnCFrame: CFrame, -- Original home transform.
	State: AIState, -- Current finite-state-machine state.
	Target: Player?, -- Player selected by target acquisition.
	TargetCharacter: Model?, -- Character model belonging to the selected player.
	LastAttackTime: number, -- Timestamp used for cooldown validation.
	LastPathTime: number, -- Timestamp used to throttle path requests.
	LastTargetPosition: Vector3?, -- Last destination used for movement-change checks.
	Waypoints: {PathWaypoint}, -- Ordered route returned by PathfindingService.
	WaypointIndex: number, -- Current waypoint index.
	MoveConnection: RBXScriptConnection?, -- Advances the route after MoveTo completes.
	BlockedConnection: RBXScriptConnection?, -- Invalidates a route when a future waypoint is blocked.
	IsRunning: boolean, -- Controls the decision loop lifetime.
	IsDead: boolean, -- Terminal flag that prevents further AI work.
	LastStuckCheck: number, -- Time of the previous progress sample.
	LastStuckPosition: Vector3, -- Position recorded during the previous sample.
	StuckCount: number, -- Consecutive samples with insufficient movement.
	PatrolDestination: Vector3?, -- Current patrol destination, if assigned.
	Config: NPCConfig, -- Per-controller copy of tunable values.
}
-- Npc template
local templateInstance = ServerStorage:WaitForChild(
	CONFIG.NPCModelName,
	10
)
--just make sure if smth wrong with a Model
assert(
	templateInstance and templateInstance:IsA("Model"),
	"Loyd NPC AI: ServerStorage.NPCModel must be a Model"
)
-- Narrow the validated Instance to Model for typed model operations.
local npcTemplate = templateInstance :: Model
-- Reuse the runtime container instead of creating duplicate folders.
local npcFolder = Workspace:FindFirstChild(CONFIG.NPCFolderName)
-- Validate this condition before executing the branch.
if not npcFolder then
	-- Store the calculated value used by the next validation or state transition.
	npcFolder = Instance.new("Folder")
	-- Store the calculated value used by the next validation or state transition.
	npcFolder.Name = CONFIG.NPCFolderName
	-- Store the calculated value used by the next validation or state transition.
	npcFolder.Parent = Workspace
end
-- CHARACTER VALIDATION: reject missing, dead, or incomplete player rigs.
-- Validate the player rig once so targeting never uses a dead or incomplete character.
local function GetLivingCharacter(player: Player): (Model?, Humanoid?, BasePart?)
	-- Current character snapshot; it may be nil while the player respawns.
	local character = player.Character
	-- A player can temporarily have no character while respawning.
	if not character then
		-- Return the validated result or stop this branch before invalid state is used.
		return nil, nil, nil
	end
	-- Health component reused by the following validity checks.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	-- Root part reused for consistent spatial calculations.
	local root = character:FindFirstChild("HumanoidRootPart")
	-- Dead characters cannot be selected as combat targets.
	if not humanoid or humanoid.Health <= 0 then
		-- Return the validated result or stop this branch before invalid state is used.
		return nil, nil, nil
	end
	-- A valid root part is required for spatial calculations.
	if not root or not root:IsA("BasePart") then
		-- Return the validated result or stop this branch before invalid state is used.
		return nil, nil, nil
	end
	-- Return the validated result or stop this branch before invalid state is used.
	return character, humanoid, root
end
-- VECTOR HELPERS: keep orientation calculations horizontal.
-- Flatten a world-space offset so facing checks ignore elevation changes.
local function GetHorizontalDirection(
	fromPosition: Vector3,
	toPosition: Vector3
): Vector3
	-- Offset used by the following orientation or ray calculation.
	local direction = toPosition - fromPosition
	-- Return the validated result or stop this branch before invalid state is used.
	return Vector3.new(direction.X, 0, direction.Z)
end
-- Use a dot product to validate facing without calculating an angle.
local function IsFacingTarget(
	root: BasePart,
	targetPosition: Vector3,
	minimumDot: number
): boolean
	-- Offset used by the following orientation or ray calculation.
	local direction = GetHorizontalDirection(
		root.Position,
		targetPosition
	)
	-- Avoid constructing a look-at transform from a zero-length direction.
	if direction.Magnitude <= 0.001 then
		-- Return the validated result or stop this branch before invalid state is used.
		return true
	end
	-- Return the validated result or stop this branch before invalid state is used.
	return root.CFrame.LookVector:Dot(direction.Unit) >= minimumDot
end
-- LINE OF SIGHT: use a filtered raycast to reject occluded targets.
-- Raycast toward the target while excluding the observer NPC from the query.
local function HasLineOfSight(
	origin: Vector3,
	targetCharacter: Model,
	targetPosition: Vector3,
	ignoredModel: Model
): boolean
	-- Offset used by the following orientation or ray calculation.
	local direction = targetPosition - origin
	-- Per-query raycast filter settings.
	local params = RaycastParams.new()
	-- Store the calculated value used by the next validation or state transition.
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Store the calculated value used by the next validation or state transition.
	params.FilterDescendantsInstances = { ignoredModel }
	-- Store the calculated value used by the next validation or state transition.
	params.IgnoreWater = true
	-- First ray hit used to determine whether geometry blocks the target.
	local result = Workspace:Raycast(origin, direction, params)
	-- No ray hit means the segment to the target is unobstructed.
	if not result then
		-- Return the validated result or stop this branch before invalid state is used.
		return true
	end
	-- Return the validated result or stop this branch before invalid state is used.
	return result.Instance:IsDescendantOf(targetCharacter)
end
-- TARGET ACQUISITION: filter candidates before performing visibility checks.
-- Select the nearest living player who passes distance, FOV, and visibility checks.
local function FindBestTarget(
	npcModel: Model,
	npcRoot: BasePart,
	detectionRadius: number
): (Player?, Model?, BasePart?)
	-- Player associated with the nearest valid candidate.
	local bestPlayer: Player? = nil
	-- Character model paired with the selected player.
	local bestCharacter: Model? = nil
	-- Root part paired with the selected character.
	local bestRoot: BasePart? = nil
	-- Current best distance; only a closer candidate can replace it.
	local bestDistance = detectionRadius
	-- Iterate each configured candidate once and apply the same validation sequence.
	for _, player in Players:GetPlayers() do
		-- Current character snapshot; it may be nil while the player respawns.
		local character, humanoid, targetRoot = GetLivingCharacter(player)
		-- A player can temporarily have no character while respawning.
		if not character or not humanoid or not targetRoot then
			continue
		end
		-- Target displacement reused for both direction and distance checks.
		local offset = targetRoot.Position - npcRoot.Position
		-- Cached scalar distance avoids repeating vector magnitude calculations.
		local distance = offset.Magnitude
		-- Skip candidates that cannot improve the nearest-target result.
		if distance >= bestDistance then
			continue
		end
		local horizontalDirection = GetHorizontalDirection(
			npcRoot.Position,
			targetRoot.Position
		)
		-- Validate this condition before executing the branch.
		if horizontalDirection.Magnitude > 0.001 then
			local dot = npcRoot.CFrame.LookVector:Dot(
				horizontalDirection.Unit
			)
			local minimumDot = math.cos(
				-- Derive the scalar value used by the spatial or timing calculation.
				math.rad(CONFIG.FieldOfViewDegrees * 0.5)
			)
			-- Reject candidates outside the NPC forward viewing cone.
			if dot < minimumDot then
				continue
			end
		end
		-- Validate this condition before executing the branch.
		if CONFIG.RequireLineOfSight then
			local visible = HasLineOfSight(
				-- Construct the world-space vector used by the following spatial calculation.
				npcRoot.Position + Vector3.new(0, 2, 0),
				character,
				-- Construct the world-space vector used by the following spatial calculation.
				targetRoot.Position + Vector3.new(0, 1, 0),
				npcModel
			)
			-- Occluded players are not eligible for acquisition.
			if not visible then
				continue
			end
		end
		-- Store the calculated value used by the next validation or state transition.
		bestDistance = distance
		-- Store the calculated value used by the next validation or state transition.
		bestPlayer = player
		-- Store the calculated value used by the next validation or state transition.
		bestCharacter = character
		-- Store the calculated value used by the next validation or state transition.
		bestRoot = targetRoot
	end
	-- Return the validated result or stop this branch before invalid state is used.
	return bestPlayer, bestCharacter, bestRoot
end
-- NPC CONTROLLER: shared methods avoid duplicating behavior per instance.
local NPCControllerClass = {}
-- Store the calculated value used by the next validation or state transition.
NPCControllerClass.__index = NPCControllerClass
-- Create isolated runtime state; the metatable shares methods between controller instances.
function NPCControllerClass.new(model: Model): NPCController
	-- Health component reused by the following validity checks.
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	-- Root part reused for consistent spatial calculations.
	local root = model:FindFirstChild("HumanoidRootPart")
	-- Fail startup with a clear message if the required rig structure is invalid.
	assert(humanoid, "NPCModel requires a Humanoid")
	-- Fail startup with a clear message if the required rig structure is invalid.
	assert(
		root and root:IsA("BasePart"),
		"NPCModel requires a BasePart named HumanoidRootPart"
	)
	-- Controller state table attached to the shared method table.
	local controller = setmetatable({
		Model = model,
		Humanoid = humanoid,
		Root = root,
		SpawnCFrame = model:GetPivot(),
		State = "Idle",
		Target = nil,
		TargetCharacter = nil,
		LastAttackTime = 0,
		LastPathTime = 0,
		LastTargetPosition = nil,
		Waypoints = {},
		WaypointIndex = 0,
		MoveConnection = nil,
		BlockedConnection = nil,
		IsRunning = false,
		IsDead = false,
		LastStuckCheck = os.clock(),
		LastStuckPosition = root.Position,
		StuckCount = 0,
		PatrolDestination = nil,
		Config = {
			DetectionRadius = CONFIG.DetectionRadius, -- Maximum range for acquiring a new player target.
			LoseTargetRadius = CONFIG.LoseTargetRadius, -- Larger release radius prevents target flicker near the acquisition boundary.
			AttackRange = CONFIG.AttackRange, -- Maximum distance allowed when an attack begins.
			AttackDamage = CONFIG.AttackDamage, -- Server-applied damage after delayed validation succeeds.
			AttackCooldown = CONFIG.AttackCooldown, -- Minimum interval between attack starts.
			WalkSpeed = CONFIG.WalkSpeed, -- Speed used for patrol and returning home.
			ChaseSpeed = CONFIG.ChaseSpeed, -- Speed used while pursuing a player.
		},
	}, NPCControllerClass)
	-- Return the validated result or stop this branch before invalid state is used.
	return controller :: any
end
-- STATE MANAGEMENT: centralize transition side effects and route invalidation.
-- Centralize transition side effects so speed and route state remain synchronized.
function NPCControllerClass.SetState(
	self: NPCController,
	newState: AIState
): ()
	-- Avoid repeating transition side effects or reviving a terminal controller.
	if self.State == newState or self.IsDead then
		return
	end
	-- Commit the new state before applying its side effects.
	self.State = newState
	-- Validate this condition before executing the branch.
	if newState == "Chase" then
		-- Update controller state so the next decision cycle observes the new value.
		self.Humanoid.WalkSpeed = self.Config.ChaseSpeed
		-- Evaluate the next mutually exclusive condition in the state decision.
	elseif newState == "Patrol" or newState == "Return" then
		-- Update controller state so the next decision cycle observes the new value.
		self.Humanoid.WalkSpeed = self.Config.WalkSpeed
		-- Evaluate the next mutually exclusive condition in the state decision.
	elseif newState == "Idle" or newState == "Attack" then
		-- Update controller state so the next decision cycle observes the new value.
		self.Humanoid.WalkSpeed = 0
		-- Evaluate the next mutually exclusive condition in the state decision.
	elseif newState == "Dead" then
		-- Update controller state so the next decision cycle observes the new value.
		self.Humanoid.WalkSpeed = 0
	end
	-- Validate this condition before executing the branch.
	if newState ~= "Chase" and newState ~= "Patrol" and newState ~= "Return" then
		self:ClearPath()
	end
end
-- Disconnect route callbacks and clear cached waypoints before changing destinations.
function NPCControllerClass.ClearPath(self: NPCController): ()
	-- Validate this condition before executing the branch.
	if self.MoveConnection then
		-- Release the callback so stale events cannot mutate the new route.
		self.MoveConnection:Disconnect()
		-- Update controller state so the next decision cycle observes the new value.
		self.MoveConnection = nil
	end
	-- Validate this condition before executing the branch.
	if self.BlockedConnection then
		-- Release the callback so stale events cannot mutate the new route.
		self.BlockedConnection:Disconnect()
		-- Update controller state so the next decision cycle observes the new value.
		self.BlockedConnection = nil
	end
	-- Clear the existing waypoint array in place to avoid replacing the table.
	table.clear(self.Waypoints)
	-- Reset route progress to the first usable waypoint.
	self.WaypointIndex = 0
	-- Cache the destination used to detect target movement.
	self.LastTargetPosition = nil
end
-- PATHFINDING: compute routes on demand and advance them through waypoint events.
-- Calculate an obstacle-aware route and connect events that advance or invalidate it.
function NPCControllerClass.ComputePath(
	self: NPCController,
	destination: Vector3
): boolean
	-- Path object configured for this NPC size and destination.
	local path = PathfindingService:CreatePath({
		AgentRadius = CONFIG.AgentRadius, -- Pathfinding clearance radius matched to the rig.
		AgentHeight = CONFIG.AgentHeight, -- Pathfinding clearance height matched to the rig.
		AgentCanJump = CONFIG.AgentCanJump, -- Allows generated paths to include jump waypoints.
		AgentJumpHeight = CONFIG.AgentJumpHeight, -- Maximum jump height considered by pathfinding.
		AgentMaxSlope = CONFIG.AgentMaxSlope, -- Maximum traversable slope angle.
	})
	-- pcall status captures ComputeAsync failures without stopping the AI loop.
	local success = pcall(function()
		path:ComputeAsync(self.Root.Position, destination)
	end)
	-- A failed computation or non-success status cannot provide usable waypoints.
	if not success or path.Status ~= Enum.PathStatus.Success then
		self:ClearPath()
		-- Return the validated result or stop this branch before invalid state is used.
		return false
	end
	self:ClearPath()
	-- Replace the cached route with the newly computed waypoint list.
	self.Waypoints = path:GetWaypoints()
	-- Derive the scalar value used by the spatial or timing calculation.
	self.WaypointIndex = math.min(2, #self.Waypoints)
	-- An empty route has no waypoint for Humanoid to follow.
	if #self.Waypoints == 0 then
		-- Return the validated result or stop this branch before invalid state is used.
		return false
	end
	-- Subscribe to the engine event so progress is handled asynchronously instead of polled.
	self.BlockedConnection = path.Blocked:Connect(function(blockedIndex)
		-- Validate this condition before executing the branch.
		if blockedIndex >= self.WaypointIndex then
			-- Mark the route stale so the next decision cycle can recompute it.
			self.LastPathTime = 0
		end
	end)
	-- Subscribe to the engine event so progress is handled asynchronously instead of polled.
	self.MoveConnection = self.Humanoid.MoveToFinished:Connect(function(reached)
		-- Validate this condition before executing the branch.
		if not reached or self.IsDead then
			-- Mark the route stale so the next decision cycle can recompute it.
			self.LastPathTime = 0
			return
		end
		-- Update controller state so the next decision cycle observes the new value.
		self.WaypointIndex += 1
		-- Validate this condition before executing the branch.
		if self.WaypointIndex <= #self.Waypoints then
			self:MoveToNextWaypoint()
		end
	end)
	-- Cache the destination used to detect target movement.
	self.LastTargetPosition = destination
	-- Return the validated result or stop this branch before invalid state is used.
	return true
end
-- Send the current waypoint to Humanoid and preserve pathfinding jump actions.
function NPCControllerClass.MoveToNextWaypoint(
	self: NPCController
): ()
	local waypoint = self.Waypoints[self.WaypointIndex]
	-- A missing waypoint index means the route has been consumed.
	if not waypoint then
		return
	end
	-- Validate this condition before executing the branch.
	if waypoint.Action == Enum.PathWaypointAction.Jump then
		-- Update controller state so the next decision cycle observes the new value.
		self.Humanoid.Jump = true
	end
	-- Delegate physical movement to Humanoid for this destination.
	self.Humanoid:MoveTo(waypoint.Position)
end
-- Reuse the cached route until the target moves or the route expires.
function NPCControllerClass.FollowPath(
	self: NPCController,
	destination: Vector3
): ()
	-- Single clock sample keeps related timing checks consistent.
	local now = os.clock()
	-- Detect stale destination data without recalculating every update.
	local targetMoved = self.LastTargetPosition == nil
		or (destination - self.LastTargetPosition).Magnitude
		>= CONFIG.TargetMoveThreshold
	-- Refresh the route after its configured lifetime.
	local pathExpired = now - self.LastPathTime
		-- Store the calculated value used by the next validation or state transition.
		>= CONFIG.PathRecomputeInterval
	-- Refresh only when the destination or route lifetime makes the cache stale.
	if targetMoved or pathExpired then
		-- Mark the route stale so the next decision cycle can recompute it.
		self.LastPathTime = now
		-- One request is sufficient; repeating identical inputs cannot change the route result.
		-- Store whether route creation succeeded before choosing fallback movement.
		local computed = self:ComputePath(destination)
		-- Validate this condition before executing the branch.
		if not computed then
			-- Delegate physical movement to Humanoid for this destination.
			self.Humanoid:MoveTo(destination)
			return
		end
		self:MoveToNextWaypoint()
	end
end
-- STUCK DETECTION: sample movement over time instead of checking every frame.
-- Measure displacement over time and request recovery when movement stalls.
function NPCControllerClass.CheckStuck(self: NPCController): ()
	-- Single clock sample keeps related timing checks consistent.
	local now = os.clock()
	-- Validate this condition before executing the branch.
	if now - self.LastStuckCheck < CONFIG.StuckCheckInterval then
		return
	end
	-- Displacement since the previous stuck-check sample.
	local movedDistance = (
		self.Root.Position - self.LastStuckPosition
	).Magnitude
	-- Count a stall only while Humanoid is trying to move but position barely changes.
	if movedDistance < CONFIG.StuckDistanceThreshold
		and self.Humanoid.MoveDirection.Magnitude > 0.1 then
		-- Update controller state so the next decision cycle observes the new value.
		self.StuckCount += 1
		-- Mark the route stale so the next decision cycle can recompute it.
		self.LastPathTime = 0
		-- Validate this condition before executing the branch.
		if self.StuckCount >= CONFIG.StuckRepathLimit then
			-- Update controller state so the next decision cycle observes the new value.
			self.Humanoid.Jump = true
			-- Update consecutive stalled samples for bounded recovery.
			self.StuckCount = 0
		end
	else
		-- Update consecutive stalled samples for bounded recovery.
		self.StuckCount = 0
	end
	-- Save the current position as the next progress baseline.
	self.LastStuckPosition = self.Root.Position
	-- Advance the timestamp to maintain the configured sample interval.
	self.LastStuckCheck = now
end
-- TARGET TRACKING: hysteresis reduces unnecessary target switching.
-- Retain a valid target inside the release radius; reacquire only when necessary.
function NPCControllerClass.UpdateTarget(self: NPCController): ()
	-- Existing target checked before scanning the full player list.
	local currentPlayer = self.Target
	-- Validate the current target before scanning every player again.
	if currentPlayer then
		-- Current character snapshot; it may be nil while the player respawns.
		local character, humanoid, root = GetLivingCharacter(currentPlayer)
		-- Keep the current target while it remains alive and within release range.
		if character and humanoid and root then
			-- Cached scalar distance avoids repeating vector magnitude calculations.
			local distance = (root.Position - self.Root.Position).Magnitude
			-- Validate this condition before executing the branch.
			if distance <= self.Config.LoseTargetRadius then
				-- Update controller state so the next decision cycle observes the new value.
				self.TargetCharacter = character
				return
			end
		end
	end
	-- Update controller state so the next decision cycle observes the new value.
	self.Target = nil
	-- Update controller state so the next decision cycle observes the new value.
	self.TargetCharacter = nil
	local player, character = FindBestTarget(
		self.Model,
		self.Root,
		self.Config.DetectionRadius
	)
	-- Update controller state so the next decision cycle observes the new value.
	self.Target = player
	-- Update controller state so the next decision cycle observes the new value.
	self.TargetCharacter = character
end
-- Rotate the complete rig toward the target without changing its position.
function NPCControllerClass.FacePosition(
	self: NPCController,
	position: Vector3
): ()
	-- Offset used by the following orientation or ray calculation.
	local direction = GetHorizontalDirection(
		self.Root.Position,
		position
	)
	-- Avoid constructing a look-at transform from a zero-length direction.
	if direction.Magnitude <= 0.001 then
		return
	end
	-- Move the complete model through its pivot rather than offsetting individual parts.
	self.Model:PivotTo(CFrame.lookAt(
		self.Root.Position,
		self.Root.Position + direction.Unit
		))
end
-- COMBAT: the server validates attacks before and after their windup.
-- Start a cooldown-gated attack and revalidate the target after its windup.
function NPCControllerClass.PerformAttack(
	self: NPCController,
	targetCharacter: Model,
	targetHumanoid: Humanoid,
	targetRoot: BasePart
): ()
	-- Single clock sample keeps related timing checks consistent.
	local now = os.clock()
	-- Enforce cooldown before starting another attack sequence.
	if now - self.LastAttackTime < self.Config.AttackCooldown then
		return
	end
	-- Do not begin a windup against a target that is already dead.
	if targetHumanoid.Health <= 0 then
		return
	end
	-- Cached scalar distance avoids repeating vector magnitude calculations.
	local distance = (targetRoot.Position - self.Root.Position).Magnitude
	-- Reject an attack that begins outside melee range.
	if distance > self.Config.AttackRange then
		return
	end
	-- Reserve the cooldown at attack start to prevent overlapping attacks.
	self.LastAttackTime = now
	self:SetState("Attack")
	self:FacePosition(targetRoot.Position)
	-- Schedule a one-shot action without blocking the AI decision loop.
	task.delay(CONFIG.AttackWindup, function()
		-- Cancel delayed work if the controller or its model no longer exists.
		if self.IsDead or not self.Model.Parent then
			return
		end
		-- The original target may have despawned during windup.
		if not targetCharacter.Parent or targetHumanoid.Health <= 0 then
			return
		end
		-- Fresh root lookup because the target may respawn during attack windup.
		local currentTargetRoot = targetCharacter:FindFirstChild(
			"HumanoidRootPart"
		)
		-- The target may have respawned or changed rigs during windup.
		if not currentTargetRoot or not currentTargetRoot:IsA("BasePart") then
			return
		end
		-- Impact-time range check; the target may move during windup.
		local currentDistance = (
			currentTargetRoot.Position - self.Root.Position
		).Magnitude
		-- The target must remain close when the windup finishes.
		if currentDistance > self.Config.AttackRange + 1 then
			return
		end
		-- Require the NPC to face the target at impact time.
		if not IsFacingTarget(
			self.Root,
			currentTargetRoot.Position,
			CONFIG.AttackFacingDot
			) then
			return
		end
		-- Apply damage on the server after the target passes final validation.
		targetHumanoid:TakeDamage(self.Config.AttackDamage)
	end)
end
-- Generate a random patrol destination around the original spawn point.
function NPCControllerClass.GetPatrolPoint(
	self: NPCController
): Vector3
	-- Random horizontal direction for the next patrol point.
	local angle = math.random() * math.pi * 2
	-- Cached scalar distance avoids repeating vector magnitude calculations.
	local distance = math.random() * CONFIG.PatrolRadius
	-- Return the validated result or stop this branch before invalid state is used.
	return self.SpawnCFrame.Position + Vector3.new(
		-- Derive the scalar value used by the spatial or timing calculation.
		math.cos(angle) * distance,
		0,
		-- Derive the scalar value used by the spatial or timing calculation.
		math.sin(angle) * distance
	)
end
-- Move the NPC back to its home transform before patrol resumes.
function NPCControllerClass.ReturnHome(self: NPCController): ()
	-- Cached scalar distance avoids repeating vector magnitude calculations.
	local distance = (
		-- Build the transform used to orient or position the complete rig.
		self.Root.Position - self.SpawnCFrame.Position
	).Magnitude
	-- Stop returning once the NPC reaches its home radius.
	if distance <= CONFIG.WaypointReachedDistance then
		self:SetState("Idle")
		-- Store or clear the point used by patrol behavior.
		self.PatrolDestination = nil
		return
	end
	self:SetState("Return")
	-- Build the transform used to orient or position the complete rig.
	self:FollowPath(self.SpawnCFrame.Position)
	self:CheckStuck()
end
-- AI DECISION: select one behavior branch per update.
-- Run one finite-state decision cycle and choose the current behavior.
function NPCControllerClass.Think(self: NPCController): ()
	-- A dead Humanoid must not continue into target selection or movement.
	if self.IsDead or self.Humanoid.Health <= 0 then
		self:SetState("Dead")
		return
	end
	self:UpdateTarget()
	local targetCharacter = self.TargetCharacter
	-- Prefer combat behavior whenever a valid target is available.
	if targetCharacter then
		local targetHumanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
		local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
		-- Validate both target components before calculating combat distance.
		if targetHumanoid
			and targetHumanoid.Health > 0
			and targetRoot
			and targetRoot:IsA("BasePart") then
			-- Cached scalar distance avoids repeating vector magnitude calculations.
			local distance = (
				targetRoot.Position - self.Root.Position
			).Magnitude
			-- Enter the attack branch only inside melee range.
			if distance <= self.Config.AttackRange then
				self:FacePosition(targetRoot.Position)
				-- Validate this condition before executing the branch.
				if os.clock() - self.LastAttackTime
					-- Store the calculated value used by the next validation or state transition.
					>= self.Config.AttackCooldown then
					self:PerformAttack(
						targetCharacter,
						targetHumanoid,
						targetRoot
					)
				else
					self:SetState("Attack")
				end
			else
				self:SetState("Chase")
				self:FollowPath(targetRoot.Position)
				self:CheckStuck()
			end
			return
		end
	end
	-- Validate this condition before executing the branch.
	if (self.Root.Position - self.SpawnCFrame.Position).Magnitude
		> CONFIG.PatrolRadius + 5 then
		self:ReturnHome()
		return
	end
	-- Validate this condition before executing the branch.
	if self.State == "Idle" then
		self:SetState("Patrol")
		-- Store or clear the point used by patrol behavior.
		self.PatrolDestination = self:GetPatrolPoint()
		self:FollowPath(self.PatrolDestination)
		return
	end
	-- Validate this condition before executing the branch.
	if self.State == "Patrol" then
		local destination = self.PatrolDestination
		-- Choose a new patrol point when none exists or the current one is reached.
		if not destination
			or (self.Root.Position - destination).Magnitude
			<= CONFIG.WaypointReachedDistance then
			self:SetState("Idle")
			-- Bounded idle pause prevents predictable patrol timing.
			local waitDuration = math.random(
				CONFIG.PatrolWaitMin,
				CONFIG.PatrolWaitMax
			)
			-- Schedule a one-shot action without blocking the AI decision loop.
			task.delay(waitDuration, function()
				-- Validate this condition before executing the branch.
				if not self.IsDead and self.State == "Idle" then
					-- Store or clear the point used by patrol behavior.
					self.PatrolDestination = self:GetPatrolPoint()
					self:SetState("Patrol")
					self:FollowPath(self.PatrolDestination)
				end
			end)
		else
			self:FollowPath(destination)
			self:CheckStuck()
		end
		-- Evaluate the next mutually exclusive condition in the state decision.
	elseif self.State == "Chase" or self.State == "Attack" then
		self:SetState("Return")
		self:ReturnHome()
		-- Evaluate the next mutually exclusive condition in the state decision.
	elseif self.State == "Return" then
		self:ReturnHome()
	end
end
-- Stop the controller and release movement callbacks when its Humanoid dies.
function NPCControllerClass.OnDied(self: NPCController): ()
	-- Validate this condition before executing the branch.
	if self.IsDead then
		return
	end
	self:SetState("Dead")
	-- Mark the controller terminal before delayed tasks can resume it.
	self.IsDead = true
	-- Stop or start the controller decision loop.
	self.IsRunning = false
	self:ClearPath()
end
-- AI LOOP: run decisions at a controlled cadence and stop on death.
-- Start a throttled AI loop and subscribe to Humanoid death.
function NPCControllerClass.Start(self: NPCController): ()
	-- Prevent duplicate loops and refuse to restart a dead controller.
	if self.IsRunning or self.IsDead then
		return
	end
	-- Stop or start the controller decision loop.
	self.IsRunning = true
	-- Update controller state so the next decision cycle observes the new value.
	self.Humanoid.WalkSpeed = self.Config.WalkSpeed
	-- Subscribe to the engine event so progress is handled asynchronously instead of polled.
	self.Humanoid.Died:Connect(function()
		self:OnDied()
	end)
	-- Run the controller loop independently so spawning does not yield.
	task.spawn(function()
		-- Continue only while the controller lifecycle permits another update.
		while self.IsRunning and not self.IsDead do
			self:Think()
			-- Yield between decisions to cap server work while physics continues.
			task.wait(CONFIG.ThinkInterval)
		end
	end)
end
-- Distribute NPC spawn transforms evenly around a ring.
local function GetSpawnCFrame(index: number, count: number): CFrame
	-- Random horizontal direction for the next patrol point.
	local angle = ((index - 1) / math.max(count, 1)) * math.pi * 2
	local position = Vector3.new(
		-- Derive the scalar value used by the spatial or timing calculation.
		math.cos(angle) * CONFIG.SpawnRadius,
		CONFIG.SpawnHeight,
		-- Derive the scalar value used by the spatial or timing calculation.
		math.sin(angle) * CONFIG.SpawnRadius
	)
	-- Return the validated result or stop this branch before invalid state is used.
	return CFrame.lookAt(position, Vector3.zero)
end
-- SPAWNER: own model lifetime separately from controller behavior.
-- Clone, configure, and start one NPC; schedule a replacement after death.
local function SpawnNPC(index: number): NPCController
	-- Independent rig clone owned by this controller.
	local clone = npcTemplate:Clone()
	-- Store the calculated value used by the next validation or state transition.
	clone.Name = "LoydNPC_" .. index
	-- Move the complete model through its pivot rather than offsetting individual parts.
	clone:PivotTo(GetSpawnCFrame(index, CONFIG.NPCCount))
	-- Store the calculated value used by the next validation or state transition.
	clone.Parent = npcFolder
	-- Health component reused by the following validity checks.
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	-- Root part reused for consistent spatial calculations.
	local root = clone:FindFirstChild("HumanoidRootPart")
	-- Fail startup with a clear message if the required rig structure is invalid.
	assert(humanoid, "Cloned NPC is missing Humanoid")
	-- Fail startup with a clear message if the required rig structure is invalid.
	assert(
		root and root:IsA("BasePart"),
		"Cloned NPC is missing HumanoidRootPart"
	)
	pcall(function()
		-- Keep NPC assembly simulation server-owned for authoritative movement.
		root:SetNetworkOwner(nil)
	end)
	-- Controller state table attached to the shared method table.
	local controller = NPCControllerClass.new(clone)
	controller:Start()
	-- Subscribe to the engine event so progress is handled asynchronously instead of polled.
	humanoid.Died:Connect(function()
		-- Schedule a one-shot action without blocking the AI decision loop.
		task.delay(CONFIG.RespawnDelay, function()
			-- Validate this condition before executing the branch.
			if clone.Parent then
				clone:Destroy()
			end
			SpawnNPC(index)
		end)
	end)
	-- Return the validated result or stop this branch before invalid state is used.
	return controller
end
-- INITIALIZATION: create the configured NPC population after dependencies are ready.
-- Retain controller references for inspection and lifetime management.
local activeControllers: {NPCController} = {}
-- Iterate each configured candidate once and apply the same validation sequence.
for index = 1, CONFIG.NPCCount do
	-- Controller state table attached to the shared method table.
	local controller = SpawnNPC(index)
	-- Retain this controller in the runtime collection.
	table.insert(activeControllers, controller)
end

-- Report initialization status in Studio Output for quick verification.
print("[Loyd] HD APPLICATION: NPC AI System initialized.")
print("[Loyd] HD APPLICATION: Active NPC controllers:", #activeControllers)

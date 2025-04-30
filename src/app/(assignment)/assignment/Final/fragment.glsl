precision highp float;
varying vec2 vUv; // UV (screen) coordinates in [0,1]^2

uniform float iTime;
uniform float iTimeDelta;
uniform float iFrame;
uniform vec2 iResolution;
uniform vec4 iMouse;
uniform sampler2D iChannel0;

float remap01(float inp, float inp_start, float inp_end) {
    return clamp((inp - inp_start) / (inp_end - inp_start), 0.0, 1.0);
}
float dist_sqr(vec2 a, vec2 b) {
    vec2 diff = a - b;
    return dot(diff, diff);
}

// ------------------------------------------------------------
// Particle structure
struct Particle {
    vec2 pos;
    vec2 pos_prev;
    vec2 vel;
    float inv_mass;
    bool is_fixed;
    bool is_visible;
    bool isDraggingBall;
    bool isShot;
};

struct Box {
    vec2 pos;
    vec2 pos_prev;
    vec2 dims;
    vec2 vel;
    float inv_mass;
    bool is_fixed;
};

// Define n_rope rope particles and add one extra "mouse particle".
const int MAX_PARTICLES = 20;
const int MAX_SPRINGS = 20;
const int MAX_BOXES = 20;
const float BIRD_DIAMETER = 0.1;
const float SPRING_SHOT_RELEASE_DIST = 0.05;

// Simulation constants
const float damp = 0.4;
const float collision_dist = 0.2;
const float ground_collision_dist = BIRD_DIAMETER / 2.;
const vec2 gravity = vec2(0.0, -1);

const vec2 INIT_BALL_LOCATION = vec2(-1.0, -0.4); 
const float SPRING_STIFFNESS = 1.0 / 40.0;

// bool isShot = false;
// bool isDraggingBall = false;

//0: mouse particle
//1...5: rope particles
int n_particles;
Particle particles[MAX_PARTICLES];

int n_boxes;
Box boxes[MAX_BOXES];

bool nearest_particle(vec2 p) {
    if (length(p - particles[2].pos) < BIRD_DIAMETER / 2.) {
        return true;
    }
    return false;
}

// ------------------------------------------------------------
// Spring structure
struct Spring {
    int a;
    int b;
    float restLength;
    float inv_stiffness;
};
// Create springs between adjacent rope particles (n_rope-1 springs)
// and one spring connecting the last rope particle and the mouse particle.
Spring springs[MAX_SPRINGS];
int n_springs;
int selected_particle = -1;
int current_add_particle = -1;

Spring add_spring(int a, int b, float inv_stiffness){
    Spring s;
    s.a = a;
    s.b = b;
    s.restLength = 0.1;
    s.inv_stiffness = inv_stiffness;
    return s;
}

const int initial_particles = 3;

void init_state(void){
    n_particles = 3;
    n_springs = 2;

    //particle 0 is the mouse particle and will be set later
    particles[1].pos = vec2(-0.9, -0.2); 
    particles[1].vel = vec2(0.0);
    particles[2].pos = INIT_BALL_LOCATION; 
    particles[2].vel = vec2(0.0);
    particles[1].is_fixed = true;
    // particles[3].pos = vec2(-0, 0.5);
    // particles[3].vel = vec2(0.0);
    // particles[4].pos = vec2(0.3, 0.5);
    // particles[4].vel = vec2(0.0);
    // particles[5].pos = vec2(0.6, 0.5);
    // particles[5].vel = vec2(0.0);

    current_add_particle = initial_particles;

    // Springs between adjacent rope particles
    //spring 0 is the mouse particle to the first rope particle
    springs[1] = add_spring(1, 2, SPRING_STIFFNESS); // first to second rope particle
    // springs[2] = add_spring(2, 3, 1.0 / 100.0); // second to third rope particle
    // springs[3] = add_spring(3, 4, 1.0 / 100.0); // third to fourth rope particle
    // springs[4] = add_spring(4, 5, 1.0 / 100.0); // fourth to fifth rope particle
}


vec2 screen_to_xy(vec2 coord) {
    return (coord - 0.5 * iResolution.xy) * 2.0 / iResolution.y;
}

bool is_initializing() {
    return iTime < 0.06 || iFrame < 2.;
}

// Load rope particles from the previous frame and update the mouse particle.
void load_state() {
    //0,0: (num_particles, num_springs, selected_particle)

    vec4 data = texelFetch(iChannel0, ivec2(0, 0), 0);
    n_particles = int(data.x);
    n_springs = int(data.y);
    selected_particle = int(data.z);
    current_add_particle = int(data.w);

    //initialize mouse particle
    // {
    //     int mouse_idx = 0;
    //     particles[mouse_idx].pos = screen_to_xy(iMouse.xy);
    //     particles[mouse_idx].vel = vec2(0.0);
    //     particles[mouse_idx].inv_mass = 0.0; // fixed particle
    //     particles[mouse_idx].is_fixed = true;
    // }
    // Load other particles
    for (int i = 1; i < n_particles; i++) {
        vec4 data = texelFetch(iChannel0, ivec2(i, 0), 0);
        particles[i].pos = data.xy;
        particles[i].vel = data.zw;
        particles[i].inv_mass = 1.0; // all particles have mass 1.0
        particles[i].is_fixed = false;

        if(i==1){
            particles[i].inv_mass = 0.0; // fixed particles at the ends of the rope
            particles[i].is_fixed = true; // make sure the first and last particles are fixed
        }
        vec4 data_flags = texelFetch(iChannel0, ivec2(i, 2), 0);
        particles[i].isDraggingBall = (data_flags.x > 0.5);
        particles[i].isShot = (data_flags.y > 0.5);
    }
    particles[1].is_fixed = true;
    
    //select nearest particle to mouse
    if(iMouse.z == 1.){
        if(!particles[2].isDraggingBall && !particles[2].isShot){
            particles[2].isDraggingBall = nearest_particle(screen_to_xy(iMouse.xy));
        }
    } else if (iMouse.z == 0.) {
        if (particles[2].isDraggingBall) {
            particles[2].isDraggingBall = false;
            particles[2].isShot = true;
        }
    }

    if (particles[2].isDraggingBall) {
        particles[2].pos = vec2(screen_to_xy(iMouse.xy).x, max(-0.65 + BIRD_DIAMETER / 2., screen_to_xy(iMouse.xy).y));
    }    

    //load springs
    // springs[0] = Spring(0, selected_particle, 0.0, 1.0 / 100.0); // mouse particle to first rope particle
    for (int i = 1; i < n_springs; i++) {
        vec4 data = texelFetch(iChannel0, ivec2(i, 1), 0);
        springs[i].a = int(data.x);
        springs[i].b = int(data.y);
        springs[i].restLength = data.z;
        springs[i].inv_stiffness = data.w;
        if (particles[2].isShot) {
            if (length(particles[springs[i].a].pos - particles[springs[i].b].pos) < SPRING_SHOT_RELEASE_DIST) {
                n_springs = 1;
            }
        }
    }

    if(n_springs == 1){
        // particles[current_add_particle].pos = particles[2].pos;
        // particles[current_add_particle].vel = particles[2].vel;
        // particles[current_add_particle].inv_mass = particles[2].inv_mass;
        // particles[current_add_particle].is_fixed = particles[2].is_fixed;
        // particles[current_add_particle].isDraggingBall = particles[2].isDraggingBall;
        // particles[current_add_particle].isShot = particles[2].isShot;
        particles[current_add_particle] = particles[2];
        particles[2].pos = INIT_BALL_LOCATION; // update the position of the selected particle
        particles[2].vel = vec2(0.0); // reset velocity to zero when mouse is released
        particles[2].inv_mass = 1.0; // make sure the selected particle is fixed
        particles[2].is_fixed = false; // make sure the selected particle is fixed
        particles[2].isDraggingBall = false; // make sure the selected particle is fixed
        particles[2].isShot = false; // make sure the selected particle is fixed
        n_springs = 2;
        springs[1] = add_spring(1, 2, SPRING_STIFFNESS); // first to second rope particle
        if(current_add_particle >= n_particles){
            // If we reach the maximum number of particles, reset to the first available index.
            n_particles = current_add_particle + 1; // skip the mouse particle at index 0
        }
        current_add_particle++;
        if(current_add_particle >= MAX_PARTICLES){
            current_add_particle = initial_particles;
        }
    }
}


/////////////////////////////////////////////////////
//// Step 1.1: Computing the spring constraint
//// This function calculates the deviation of a spring's length 
//// from its rest length. The constraint is defined as L - L0, 
//// This constraint is later used to adjust the positions of particles 
//// to enforce the spring constraint.
/////////////////////////////////////////////////////
float spring_constraint(Spring s) {
    // The spring has two endpoints a and b.
    // Their positions are particles[s.a].pos and particles[s.b].pos respectively.
    // The spring constraint is L-L0, where L is the current length of the spring
    // and L0 = s.restLength is the rest length of the spring.

    //// Your implementation starts
    return length(particles[s.a].pos - particles[s.b].pos) - s.restLength;
    // return 0.;
    //// Your implementation ends
}

/////////////////////////////////////////////////////
//// Step 1.2: Computing the spring constraint gradient
//// This function calculates the gradient of the spring constraint constraint 
//// for a spring a--b with respect to the position of a.
/////////////////////////////////////////////////////
vec2 spring_constraint_gradient(vec2 a, vec2 b) {
    // Gradient of the spring constraint for points a,b with respect to a.
    // Think: what is the gradient of (a-b) with respect to a?

    //// Your implementation starts
    vec2 diff = a - b;
    float dist = length(diff);
    if (dist == 0.){
        return vec2(0.);
    }
    return diff / dist;
    //// Your implementation ends
}

// Compute the gradient of the spring constraint with respect to a given particle.
vec2 spring_constraint_grad(Spring s, int particle_idx) {
    float sgn = (particle_idx == s.a) ? 1.0 : -1.0;
    return sgn * spring_constraint_gradient(particles[s.a].pos, particles[s.b].pos);
}

/////////////////////////////////////////////////////
//// Step 1.3: Solving a single spring constraint
//// Calculate the numerator and denominator for the Lagrangian multiplier update.
//// You will calculate the numer/denom for PBD updates.
//// The Lagrangian multiplier update is calculated with lambda=(numer/denom)
//// See the documentation for more details.
/////////////////////////////////////////////////////
void solve_spring(Spring s, float dt) {   
    float numer = 0.;
    float denom = 0.;

    //// Your implementation starts
    numer = -spring_constraint(s);
    // for (int i = 0; i < n_sprin; i++) {
    vec2 grad_a = spring_constraint_gradient(particles[s.a].pos, particles[s.b].pos); 
    denom += particles[s.a].inv_mass * length(grad_a) * length(grad_a);  
    vec2 grad_b = spring_constraint_gradient(particles[s.b].pos, particles[s.a].pos); 
    denom += particles[s.b].inv_mass *length(grad_b) * length(grad_b);  
    // }
    
    //// Your implementation ends

    // PBD if you comment out the following line
    denom += s.inv_stiffness / (dt * dt);
    
    if (denom == 0.0) return;
    float lambda = numer / denom;
    particles[s.a].pos += lambda * particles[s.a].inv_mass * grad_a;
    particles[s.b].pos += lambda * particles[s.b].inv_mass * grad_b;
}

/////////////////////////////////////////////////////
//// Step 2.1: Computing the collision constraint
//// If two particles a,b are closer than collision_dist,
//// a spring constraint is applied to separate them.
//// The rest length of the spring is set to collision_dist.
//// Otherwise return 0.0.
/////////////////////////////////////////////////////
float collision_constraint(vec2 a, vec2 b, float collision_dist){
    // Compute the distance between two particles a and b.
    // The constraint is defined as L - L0, where L is the current distance between a and b
    // and L0 = collision_dist is the minimum distance between a and b.

    float dist = length(a - b);
    if(dist < collision_dist){
        //// Your implementation starts
        // return 0.0;
        return dist - collision_dist;
        //// Your implementation ends
    }
    else{
        return 0.0;
    }
}

/////////////////////////////////////////////////////
//// Step 2.2: Computing the collision constraint gradient
//// If two particles a,b are closer than collision_dist,
//// calculate the gradient of the collision constraint with respect to a.
//// It's similar to the spring constraint gradient.
//// Otherwise return vec2(0.0, 0.0).
/////////////////////////////////////////////////////
vec2 collision_constraint_gradient(vec2 a, vec2 b, float collision_dist){
    // Compute the gradient of the collision constraint with respect to a.

    float dist = length(a - b);
    if(dist <= collision_dist){
        //// Your implementation starts
        // return vec2(0.0);
        return (a - b) / dist;
        //// Your implementation ends
    }
    else{
        return vec2(0.0, 0.0);
    }
}

float particle_to_box_collision_constraint(vec2 particle_pos, vec2 box_pos, vec2 box_dim, float box_rotation, float radius) {
    // First, rotate the particle into the box's local space (unrotate the particle)
    float cos_theta = cos(-box_rotation);
    float sin_theta = sin(-box_rotation);
    
    // Translate to box-local coordinates
    vec2 local_pos = particle_pos - box_pos;

    // Rotate by inverse of box_rotation
    vec2 rotated_pos = vec2(
        local_pos.x * cos_theta - local_pos.y * sin_theta,
        local_pos.x * sin_theta + local_pos.y * cos_theta
    );

    // The box is axis-aligned in local space, centered at (0,0)
    vec2 half_dim = box_dim * 0.5;

    // Find the closest point on the box in local space
    vec2 closest_point = clamp(rotated_pos, -half_dim, half_dim);

    // Compute the distance from particle to box
    float dist = length(rotated_pos - closest_point);

    if (dist <= radius) {
        return radius - dist;
    } else {
        return 0.0;
    }
}

vec2 particle_to_box_collision_constraint_gradient(vec2 particle_pos, vec2 box_pos, vec2 box_dim, float box_rotation, float collision_dist) {
    // Rotate particle into box local frame (undo box rotation)
    float cos_theta = cos(-box_rotation);
    float sin_theta = sin(-box_rotation);

    vec2 local_pos = particle_pos - box_pos;
    vec2 rotated_pos = vec2(
        local_pos.x * cos_theta - local_pos.y * sin_theta,
        local_pos.x * sin_theta + local_pos.y * cos_theta
    );

    vec2 half_dim = box_dim * 0.5;
    vec2 closest_point = clamp(rotated_pos, -half_dim, half_dim);

    vec2 diff = rotated_pos - closest_point;
    float dist = length(diff);

    if (dist <= collision_dist && dist > 1e-6) {
        // Normalize in local box frame
        vec2 local_grad = diff / dist;

        // Rotate gradient back into world space
        float cos_theta_fwd = cos(box_rotation);
        float sin_theta_fwd = sin(box_rotation);
        vec2 world_grad = vec2(
            local_grad.x * cos_theta_fwd - local_grad.y * sin_theta_fwd,
            local_grad.x * sin_theta_fwd + local_grad.y * cos_theta_fwd
        );

        return world_grad;
    } else {
        return vec2(0.0, 0.0);
    }
}

/////////////////////////////////////////////////////
//// Step 2.3: Solving a single collision constraint
//// It solves for the collision constraint between particle i and j.
//// Calculate the numerator and denominator for the Lagrangian multiplier update.
//// You will calculate the numer/denom for PBD updates.
//// The Lagrangian multiplier update is calculated with lambda=(numer/denom)
//// See the documentation for more details.
/////////////////////////////////////////////////////
void solve_collision_constraint(int i, int j, float collision_dist, float dt){
    // Compute the collision constraint for particles i and j.
    float numer = 0.0;
    float denom = 0.0;

    //// Your implementation starts
    // vec2 grad = vec2(0); // only keep for the sake of the compiler
    numer = -collision_constraint(particles[i].pos, particles[j].pos, collision_dist);
    vec2 grad = collision_constraint_gradient(particles[i].pos, particles[j].pos, collision_dist);
    denom = particles[i].inv_mass * length(grad) * length(grad) + particles[j].inv_mass * length(grad) * length(grad);
    //// Your implementation ends

    //PBD if you comment out the following line, which is faster
    denom += (1. / 1000.) / (dt * dt);

    if (denom == 0.0) return;
    float lambda = numer / denom;
    particles[i].pos += lambda * particles[i].inv_mass * grad;
    particles[j].pos -= lambda * particles[j].inv_mass * grad;
}

float phi(vec2 p){
    // const float PI = 3.14159265359;
    // //let's do sin(x)+0.5
    // return p.y - (0.1 * sin(p.x * 2. * PI) - 0.5);
    return p.y + 0.65;
}

/////////////////////////////////////////////////////
//// Step 3.1: Computing the ground constraint
//// For a point p, if phi(p) < ground_collision_dist,
//// we set a constraint to push the point away from the ground.
//// The constraint is defined as phi(p) - ground_collision_dist.
//// Otherwise return 0.0.
/////////////////////////////////////////////////////
float ground_constraint(vec2 p, float ground_collision_dist){
    if(phi(p) < ground_collision_dist){
        //// Your implementation starts
        // return 0.0;
        return phi(p) - ground_collision_dist;
        //// Your implementation ends
    }
    else{
        return 0.0;
    }    
}

/////////////////////////////////////////////////////
//// Step 3.2: Computing the ground constraint gradient
//// If phi(p) < ground_collision_dist, 
//// compute the gradient of the ground constraint.
//// Otherwise return vec2(0.0, 0.0).
/////////////////////////////////////////////////////
vec2 ground_constraint_gradient(vec2 p, float ground_collision_dist){
    // Compute the gradient of the ground constraint with respect to p.
    const float PI = 3.14159265359;

    if(phi(p) < ground_collision_dist){
        //// Your implementation starts

        // return vec2(0.0);
        // return -vec2(-0.1 * 2. * PI * cos(2. * PI * p.x), 1.0);
        return -vec2(0.0, 1.0);
        
        //// Your implementation ends
    }
    else{
        return vec2(0.0, 0.0);
    }
}

/////////////////////////////////////////////////////
//// Step 3.3: Solving a single ground constraint
//// It solves for the ground constraint for particle i.
//// Calculate the numerator and denominator for the Lagrangian multiplier update.
//// You will calculate the numer/denom for PBD updates.
//// The Lagrangian multiplier update is calculated with lambda=(numer/denom)
//// See the documentation for more details.
/////////////////////////////////////////////////////
void solve_ground_constraint(int i, float ground_collision_dist, float dt){
    // Compute the ground constraint for particle i.
    float numer = 0.0;
    float denom = 0.0;

    //// Your implementation starts
    // vec2 grad = vec2(0.); // only keep for the sake of the compiler
    numer = ground_constraint(particles[i].pos, ground_collision_dist);
    vec2 grad = ground_constraint_gradient(particles[i].pos, ground_collision_dist);
    denom = particles[i].inv_mass * length(grad) * length(grad);

    //// Your implementation ends

    //PBD if you comment out the following line, which is faster
    denom += (1. / 1000.) / (dt * dt);

    if (denom == 0.0) return;
    float lambda = numer / denom;
    particles[i].pos += lambda * particles[i].inv_mass * grad;
}

/////////////////////////////////////////////////////
//// Step 10: Solving all constraints
//// You need to solve for all 3 types of constraints using previously defined functions:
//// 1. Spring constraints defined by springs[1] to springs[n_springs-1]
//// 2. Ground constraints for all particles (except the mouse particle 0).
//// 3. Collision constraints for all pairs of particles (except the mouse particle 0).
/////////////////////////////////////////////////////
void solve_constraints(float dt) {
    //If left mouse is pressed, calculate the spring constraint for the mouse particle to the first rope particle.
    // if(iMouse.z == 1.){
    //     solve_spring(springs[0], dt); // mouse particle to first rope particle
    // }

    // Solve all constraints

    //// Your implementation starts

    for (int i = 1; i < n_springs; i++) {
        if (!particles[2].isDraggingBall) {
            solve_spring(springs[i], dt);
        }
    }
    for (int i = 2; i < n_particles; i++) {
        solve_ground_constraint(i, ground_collision_dist, dt);
    }
    for (int i = 2; i < n_particles; i++) {
        for (int j = i + 1; j < n_particles; j++) {
            solve_collision_constraint(i, j, BIRD_DIAMETER, dt);
        }
    }

    //// Your implementation ends
}

float dist_to_segment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    // Compute the projection factor and clamp it between 0 and 1.
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    // Return the distance from p to the closest point on the segment.
    return length(pa - h * ba);
}

float poleSdf(vec2 p) {
    const vec2 dims = vec2(0.01, 0.225);
    const vec2 center = vec2(-0.9, -0.425);
    p = p - center;
    vec2 d = abs(p) - dims;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

vec3 render_scene(vec2 pixel_xy) {
    float phi = phi(pixel_xy);
    vec3 col;
    if(phi < 0.0) {
        col =  vec3(122, 183, 0) / 255.; // ground color
    }
    else{
        col = vec3(229, 242, 250) / 255.; // background color
    }
    
    float pixel_size = 2.0 / iResolution.y;
    
    // If still initializing, return the background color.
    if (is_initializing()) {
        return col;
    }

    // Render rope particles
    {
        float min_dist = 1e9;

        // if(iMouse.z == 1.){
        //     min_dist = dist_sqr(pixel_xy, particles[0].pos);
        // }

        for (int i = 2; i < n_particles; i++){
            min_dist = min(min_dist, dist_sqr(pixel_xy, particles[i].pos));
        }
        min_dist = sqrt(min_dist);

        const float radius = BIRD_DIAMETER / 2.;
        col = mix(col, vec3(229, 95, 32) / 255., remap01(min_dist, radius, radius - pixel_size));
    }
    
    // Render All springs
    {
        float min_dist = 1e9;

        // if(iMouse.z == 1.){
        //     min_dist = dist_to_segment(pixel_xy, particles[0].pos, particles[selected_particle].pos);
        // }

        for (int i = 1; i < n_springs; i++) {
            int a = springs[i].a;
            int b = springs[i].b;
            min_dist = min(min_dist, dist_to_segment(pixel_xy, particles[a].pos, particles[b].pos));
        }

        const float thickness = 0.01;
        
        col = mix(col, vec3(14, 105, 146) / 255., 0.25 * remap01(min_dist, thickness, thickness - pixel_size));
    }
    
    // Render slingshot pole
    if (poleSdf(pixel_xy) < 0.0) {
        col =  vec3(0., 0., 0.) / 255.;
    }


    // col.z = 1.0;
    return col;
}

vec4 output_color(vec2 pixel_ij){
    int i = int(pixel_ij.x);
    int j = int(pixel_ij.y);
    
    if(j == 0){
        // (0,0): (num_particles, num_springs, selected_particle)
        if(i==0){
            return vec4(float(n_particles), float(n_springs), float(selected_particle), float(current_add_particle));
        }
        else if(i < n_particles){
            //a particle
            return vec4(particles[i].pos, particles[i].vel);
        }
        else{
            return vec4(0.0, 0.0, 0.0, 1.0);
        }
    }
    else if(j == 1){
        if(i < n_springs){
            return vec4(float(springs[i].a), float(springs[i].b), springs[i].restLength, springs[i].inv_stiffness);
        }
        else{
            return vec4(0.0, 0.0, 0.0, 1.0);
        }
    } else if (j == 2) {
        if (i < n_particles) {
            float dragging = particles[i].isDraggingBall ? 1.0 : 0.0;
            float shot = particles[i].isShot ? 1.0 : 0.0;
            return vec4(dragging, shot, 0.0, 1.0);
        }
        return vec4(0.0);
    }
    else{
        vec2 pixel_xy = screen_to_xy(pixel_ij);
        vec3 color = render_scene(pixel_xy);
        return vec4(color, 1.0);
    }
}

// ------------------------------------------------------------
// Main function
void main() {
    vec2 pixel_ij = vUv * iResolution.xy;
    int pixel_i = int(pixel_ij.x);
    int pixel_j = int(pixel_ij.y);

    if(is_initializing()){
        init_state();
    }
    else{
        load_state();
        if (pixel_j == 0) {
            if (pixel_i >= n_particles) return;

            float actual_dt = min(iTimeDelta, 0.02);
            const int n_steps = 5;
            float dt = actual_dt / float(n_steps);

            for (int i = 0; i < n_steps; i++) {
                // Update rope particles only; skip updating the mouse particle since it's fixed.
                for (int j = 0; j < n_particles; j++) {
                    if (!particles[j].is_fixed) {
                        if (j != 2) {
                            particles[j].vel += dt * gravity;
                            particles[j].vel *= exp(-damp * dt);
                        }
                    }
                    // particles[j].vel *= exp(-damp * dt);
                    particles[j].pos_prev = particles[j].pos;
                    particles[j].pos += dt * particles[j].vel;
                }
                solve_constraints(dt);
                // Update velocities for rope particles only.
                for (int j = 0; j < n_particles; j++) {
                    if (!particles[j].is_fixed){
                        if (j == 2 && !particles[2].isShot) {
                            continue;
                        }
                        if (j != 2) {
                            particles[j].vel = (particles[j].pos - particles[j].pos_prev) / dt;
                            continue;
                        }
                        vec2 prevVel = particles[j].vel;
                        vec2 nextVel = (particles[j].pos - particles[j].pos_prev) / dt;
                        if (length(prevVel) > 0.0 && (length(prevVel) > length(nextVel))) {
                            n_springs = 1;
                            continue;
                        }
                        particles[j].vel = nextVel;
                    }
                }
                // Keep the mouse particle fixed by reassigning its position each step.
                int mouse_idx = 0;
                particles[mouse_idx].pos = screen_to_xy(iMouse.xy);
            }
        }
    }

    gl_FragColor = output_color(pixel_ij);
}

#include "plankdisplaytransition.h"

#include <cassert>

int main()
{
    using Action = PlankDisplayTransitionLaunch::Action;
    PlankDisplayTransitionLaunch policy;

    assert(policy.decide(false, false, 0) == Action::Wait);
    assert(policy.decide(false, true, 0) == Action::Launch);

    policy.noteSubmitted(0);
    assert(policy.decide(false, true, 0) == Action::Wait);
    assert(policy.decide(false, true, 3999) == Action::Wait);
    assert(policy.decide(false, false, 5000) == Action::Wait);
    assert(policy.decide(true, true, 500) == Action::Launch);

    policy.noteSubmitted(1000);
    assert(policy.decide(false, true, 4999) == Action::Wait);
    assert(policy.decide(false, true, 5000) == Action::Launch);
    assert(policy.decide(false, true, 5001) == Action::Wait);
    assert(policy.decide(false, true, 9000) == Action::Launch);
}

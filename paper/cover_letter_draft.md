We want to again thank the reviewers and our shepherd for their comments and criticism. As requested, we 
have made a series of changes to our paper.

In order to more clearly explain the core compiler passes, we have included extra explanatory prose, and
we have threaded a single running example through the paper, showing the incremental effects of each pass 
on the same simple program. We have also added further explanation to our example code, which the
reviewers previously found confusing. 

The reviewers also brought up some shortcomings of our paper's evaluation. We added a full explanation
of the machine we ran benchmark tests on, as well as the C compiler flags. Also, we added a discussion
of the performance of programs that illustrate weaknesses in our compilation approach.

We have expanded the section describing the intermediary language and its type system.
As the shephard noted, several reviewers were confused about the details of the type system and what it
was meant to guarantee. Through a combination of more thorough examples and additional prose, as well
as a demonstration of the types as used in the running example, we hope to have cleared up any confusion
relating to the intermediate language.

A discussion of Lattner and Adve's work, as well as the three citations mentioned by the shepherd, have been
added. 